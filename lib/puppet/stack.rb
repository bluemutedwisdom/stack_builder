require 'puppet'
require 'yaml'
require 'fileutils'
require 'erb'
#
# I would like for this to be a simple config language that does the
# following:
#    if creation blocks are specified for nodes, create them
#    if install blocks are created for nodes, then run scripts
#    via remote ssh
#
# If I add some kind of mounting support, this can be a replacement for
# vagrant
#
# for installation, I should use Nan's code and convert a specified hash
# into class declarations passed in via -e
#
class Puppet::Stack

  def self.configure_logging
    # TODO I do not want to be setting up logging here
    Puppet::Util::Log.level = :debug
    Puppet::Util::Log.newdestination(:console)
  end

  # parse the nodes that compose the stack
  def self.get_nodes(config_file)
    config = YAML.load_file(File.expand_path(config_file)) || {'nodes' => [], 'master' => {}}
    nodes  = process_config(config)
  end

  def self.build(options)
    configure_logging
    nodes           = get_nodes(options[:config])
    created_nodes   = create(options, nodes)
    installed_nodes = install(options, nodes, created_nodes)
    test_results    = test(options, nodes, created_nodes)
  end

  def self.stack_exists?(name)
    stack_file = File.join(get_stack_path, name)
    File.exists?(stack_file)
  end

  def self.create(options, nodes)
    stack_file = File.join(get_stack_path, options[:name])
    raise(Puppet::Error, "Cannot create stack :#{options[:name]}, stackfile #{stack_file} already exists. Stack names supplied via --name must be unique") if stack_exists?(options[:name])
    FileUtils.touch(File.join(stack_file))
    # create all nodes that need to be created
    created_master    = create_instances([nodes['master']])
    created_instances = create_instances(nodes['nodes'])
    created_nodes = {'nodes' => created_instances, 'master' => created_master}

    # install all nodes that need to be installed
    save(stack_file, created_nodes)
    created_nodes
  end

  def self.install(options, nodes, created_nodes)
    # figure out the hostname of the master to connect to
    puppetmaster_hostname = if created_nodes['master'].size > 0
      created_nodes['master'].values[0]['hostname']
    elsif nodes['master']
      nodes['master'].keys[0]
    else
      nil
    end

    # install all of the nodes
    installed_master = install_instances(
                         [nodes['master']],
                         created_nodes['master'],
                         'master'
                       )
    installed_instances = nodes['nodes'] == {} ? nil :  install_instances(
                                                          nodes['nodes'],
                                                          created_nodes['nodes'],
                                                          nodes['puppet_run_type'],
                                                          puppetmaster_hostname
                                                        )
  end

  def self.test(options, nodes, created_nodes)
    install_instances(nodes['nodes'], created_nodes['nodes'], 'test')
  end

  def self.destroy(options)
    destroyed_dir = File.join(get_stack_path, 'destroyed')
    FileUtils.mkdir(destroyed_dir) unless File.directory?(destroyed_dir)
    stack_file = File.join(get_stack_path, options[:name])
    raise(Puppet::Error, "Stackfile for stack to destroy #{stack_file} does not exists. Stack names supplied via --name must have corresponding stack file to be destroyed") unless File.exists?(stack_file)
    stack = YAML.load_file(stack_file)
    unless stack['master'] == {}
      master_hostname = stack['master'].values[0]['hostname'] if stack['master']
      Puppet.notice("Destroying master #{master_hostname}")
      Puppet::Face[:node_aws, :current].terminate(master_hostname, {:region => stack['master'].values[0]['region']})
    end
    stack['nodes'].each do |name, attrs|
      Puppet.notice("Destroying agent #{attrs['hostname']}")
      Puppet::Face[:node_aws, :current].terminate(attrs['hostname'], {:region => attrs['region']})
    end
    FileUtils.mv(stack_file, File.join(destroyed_dir, "#{options[:name]}-#{Time.now.to_i}"))
  end

  def self.list(options)
    Puppet.notice('listing active stacks')
    Dir[File.expand_path("~/.puppet/stacks/*")].each do |file|
      if File.file?(file)
        Puppet.notice("Active stack: #{File.basename(file)}") if File.file?(file)
        puts YAML.load_file(file).inspect
      end
    end
  end

  def self.tmux(options)
    raise Puppet::Error "Error: tmux not available, please install tmux." if `which tmux`.empty?

    file    = File.join(get_stack_path, options[:name])
    systems = YAML.load_file(file) if File.file?(file)
    systems ||= {}

    config = get_nodes(options[:config])

    master = config['master'] || {}
    require 'pp'

    ssh = ''
    master.each do |name, opt|
      begin
        hostname = systems['nodes'][name]['hostname']
      rescue
        hostname = name
      end
      keyfile = opt['install']['options']['keyfile']
      login   = opt['install']['options']['login']
      ssh     = "'ssh -A -i #{keyfile} #{login}@#{hostname}'"
    end

    Puppet.debug "tmux new-session -s #{options[:name]} -n master -d #{ssh}"
    `tmux new-session -s #{options[:name]} -n master -d #{ssh}`

    nodenum = 1
    # We assume the connection info is consistent throughout create, install, test.
    nodes   = config['nodes'].inject({}) { |res, elm| res= elm.merge(res) }

    nodes.keys.sort.each do |name|
      opt = nodes[name]
      begin
        hostname = systems['nodes'][name]['hostname']
      rescue
        hostname = name
      end
      keyfile = opt['install']['options']['keyfile']
      login   = opt['install']['options']['login']
      ssh     = "'ssh -A -i #{keyfile} #{login}@#{hostname}'"

      Puppet.debug "tmux new-window -t #{options[:name]}:#{nodenum} -n #{name} #{ssh}"
      `tmux new-window -t #{options[:name]}:#{nodenum} -n #{name} #{ssh} 2>&1`
      nodenum += 1
    end

    puts "Connecting to session: tmux attach-session -t #{options[:name]}"
    `tmux attach-session -t #{options[:name]}`
  end

  def self.save(name, stack)
    Puppet.warning('Save has not yet been implememted')
    File.open(name, 'w') do |fh|
      fh.puts(stack.to_yaml)
    end
  end

  # takes a config file and returns a hash of
  # nodes to build
  def self.process_config(config_hash)
    nodes = {}
    master = {}
    creation_defaults = {}
    installation_defaults = {}
    # apply the defaults
    if(config_hash['defaults'])
      Puppet.debug('Getting defaults')
      creation_defaults = config_hash['defaults']['create'] || {}
      installation_defaults = config_hash['defaults']['install'] || {}
    else
      Puppet.debug("No defaults specified")
    end
    if config_hash['master']
      master = config_hash['master']
      raise(Puppet::Error, 'only a single master is supported') if master.size > 1
      master.each do |name, attr|
        if attr
          if master[name].has_key?('create')
            master[name]['create'] ||= {}
            master[name]['create']['options'] = (creation_defaults['options'] || {}).merge(attr['create']['options'] || {})
          end
          if master[name].has_key?('install')
            # TODO I am not yet merging over non-options
            master[name]['install'] ||= {}
            master[name]['install']['options'] = (installation_defaults['options'] || {}).merge(attr['install']['options'] || {})
          end
        end
      end
    end
    if config_hash['nodes']
      nodes = config_hash['nodes']
      nodes.each_index do |index|
        node = nodes[index]
        raise(Puppet::Error, 'Nodes are suposed to be an array of Hashes') unless node.is_a?(Hash)
        # I want to support groups of nodes that can run at the same time
        #raise(Puppet::Error, 'Each node element should be composed of a single hash') unless node.size == 1
        node.each do |name, attr|
          if nodes[index][name].has_key?('create')
            nodes[index][name]['create'] ||= {}
            nodes[index][name]['create']['options'] = (creation_defaults['options'] || {}).merge(attr['create']['options'] || {})
          end
          if nodes[index][name].has_key?('install')
            # TODO I am not yet merging over non-options
            nodes[index][name]['install'] ||= {}
            nodes[index][name]['install']['options'] = (installation_defaults['options'] || {}).merge(attr['install']['options'] || {})
          end
          if nodes[index][name].has_key?('test')
            # the install options are the defaults for test!!!
            nodes[index][name]['test'] ||= {}
            nodes[index][name]['test']['options'] = (installation_defaults['options'] || {}).merge(attr['test']['options'] || {})
          end
        end
      end
    end
    {
      'nodes' => nodes,
      'master' => master,
      'puppet_run_type' => config_hash['puppet_run_type'] || 'apply'
    }
  end

  # run what ever tests need to be run
  def self.test_instances(nodes, dns_hash)
    install_instances(nodes, dns_hash, 'test')
  end

  # install all of the nodes in order
  def self.install_instances(nodes, dns_hash, mode, master = nil)
    begin
      # this setting of confdir sucks
      # I need to patch cloud provisioner to allow arbitrary
      # paths to be set
      old_puppet_dir = Puppet[:confdir]
      stack_dir = get_stack_path
      script_dir = File.join(stack_dir, 'scripts')
      unless File.directory?(script_dir)
        Puppet.info("Creating script directory: #{script_dir}")
        FileUtils.mkdir_p(script_dir)
      end
      Puppet[:confdir] = stack_dir
      nodes.each do |node|
        threads = []
        queue.clear
        # each of these can be done in parallel
        # except can our puppetmaster service simultaneous requests?
        node.each do |name, attrs|
          if ['master', 'agent', 'apply'].include?(mode)
            run_type = 'install'
          elsif mode == 'test'
            run_type = 'test'
          else
            raise(Puppet::Error, "Unexpected mode #{mode}")
          end
          if attrs and attrs[run_type]
            Puppet.info("#{run_type.capitalize}ing instance #{name}")
            # the hostname is either the node id or the hostname value
            # in the case where we cannot determine the hostname
            hostname = dns_hash[name] ? dns_hash[name]['hostname'] : name
            certname = case(mode)
              when 'master' then hostname
              else name
            end
            script_name = script_file_name(hostname)
            # compile our script into a file to perform puppet run
            File.open(File.join(script_dir, "#{script_name}.erb"), 'w') do |fh|
              fh.write(compile_erb(mode, attrs[run_type].merge('certname' => certname, 'puppetmaster' => master)))
            end
            threads << Thread.new do
              result = install_instance(
                hostname,
                (attrs[run_type]['options'] || {}).merge(
                  {'install_script' => script_name}
                )
              )
              Puppet.info("Adding instance #{hostname} to queue.")
              queue.push({name => {'result' => result}})
            end
          end
        end
        threads.each do  |aThread|
          begin
            aThread.join
          rescue Exception => spawn_err
            puts("Failed spawning AWS node: #{spawn_err}")
          end
        end
      end
    ensure
      Puppet[:confdir] = old_puppet_dir
    end
  end

  # installation helpers
  # returns the path where install scripts are located
  # this is here in part for mocking out the path where
  # sripts are loaded from
  def self.get_stack_path
    File.expand_path(File.join('~', '.puppet', 'stacks'))
  end

  def self.script_file_name(hostname)
    "#{hostname}-#{Time.now.to_i}"
  end

  def self.compile_erb(name, options)
    ERB.new(File.read(find_template(name))).result(binding)
  end

  def self.find_template(name)
    File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'scripts', "#{name}.erb"))
  end

  # for each of the instances that we need to create
  # spawn a new thread
  def self.create_instances(nodes)
    threads = []
    queue.clear
    nodes.each do |node|
      node.each do |name, attrs|
        if attrs and attrs['create']
          threads << Thread.new do
            Puppet.info("Building instance #{name}")
            # TODO I may want to capture more data when nodes
            # are created
            hostname = create_instance(attrs['create']['options'])
            Puppet.info("Adding instance #{hostname} to queue.")
            queue.push({name => {'hostname' => hostname, 'region' => attrs['create']['options']['region']}})
          end
        end
      end
    end
    threads.each do  |aThread|
      begin
        aThread.join
      rescue Exception => spawn_err
        puts("Failed spawning AWS node: #{spawn_err}")
      end
    end
    created_instances = {}
    until queue.empty?
      created_instances.merge!(queue.pop)
    end
    created_instances
  end

  def self.install_instance(hostname, options)
    Puppet.debug("Calling puppet node install with #{options.inspect}")
    Puppet::Face[:node, :current].install(hostname, options)
  end

  def self.create_instance(options, create_type = :node_aws)
    Puppet.debug("Calling puppet #{create_type} create with #{options.inspect}")
    Puppet::Face[create_type, :current].create(options)
  end

  # retrieve the queue instance
  def self.queue
    @queue ||= Queue.new
  end

  # methods to add options
  def self.add_option_name(action)
    action.option '--name=' do
      summary 'identifier that refers to the specified deployment'
      required
    end
  end

  def self.add_option_config(action)
    action.option '--config=' do
      summary 'Config file used to specify the multi node deployment to build'
      description <<-EOT
      Config file used to specficy how to build out stacks of nodes.
      EOT
      required
    end
  end
end
