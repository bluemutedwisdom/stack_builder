require 'puppet/face'
require 'spec_helper'
require 'puppet/stack'
require 'tempfile'
describe Puppet::Stack do

  let :node_face do
    Puppet::Face[:node_aws, :current]
  end

  let :default_params do
    {:name => 'dans_stack',
     :config => 'foo'
    }
  end

  before :each do
    @tempfile = Tempfile.open('config')
    tmpfile = Tempfile.open('config')
    tmpfile.close
    @puppet_dir = tmpfile.path
    @stack_dir = File.join(tmpfile.path, 'stacks')
    tmpfile.unlink
    FileUtils.mkdir_p(@stack_dir)
    Puppet::Stack.expects(:get_puppet_path).at_least_once.returns(@puppet_dir)
  end

  after :each do
    @tempfile.unlink
    FileUtils.rm_rf(@stack_dir)
  end

  def write_node_hash(node_hash)
    @tempfile.puts(node_hash.to_yaml)
    @tempfile.close
  end

  describe 'when building stacks' do
    it 'should not create any nodes when the config is empty' do
      @tempfile.puts ''
      node_face.expects(:create).never
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    end

    it 'should create a single node when one is specified' do
      node = {'nodes' =>
        ['node_one' =>
          {'create' => { 'options' => {'group' => 'default', 'image' => 'ami-123'}}}
        ]
      }
      write_node_hash(node)
      node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123'}).returns('localhost')
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    end

    it 'should use default options if node specific ones are not specified' do
      node = {
        'defaults' => {
          'create' => { 'options' => {
            'type' => 't1.tiny',
          }}
        },
        'nodes' => [
          'node_one' => {
            'create' => { 'options' => {
              'group' => 'default', 'image' => 'ami-123'
            }}
          }
        ]
      }
      write_node_hash(node)
      node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123', 'type' => 't1.tiny'})
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    end
    it 'should override default options with node specific values' do
      node = {
        'defaults' => {
          'create' => { 'options' => {
            'type' => 't1.tiny',
          }}
        },
        'nodes' => [
          'node_one' => {
            'create' => { 'options' => {
              'group' => 'default',
              'image' => 'ami-123',
              'type'  => 'm1.small'
            }}
          }
        ]
      }
      write_node_hash(node)
      node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123', 'type' => 'm1.small'})
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    end
    it 'should apply defaults to all nodes' do
      node = {
        'defaults' => {
          'create' => { 'options' => {
            'type' => 't1.tiny',
          }}
        },
        'nodes' => [
          {'node_one' => {
            'create' => { 'options' => {
              'group' => 'default',
              'image' => 'ami-123',
            }}
          }},
          {'node_two' => {
            'create' => { 'options' => {
              'group' => 'default',
              'image' => 'ami-123',
            }}
          }}
        ]
      }
      write_node_hash(node)
      node_face.expects(:create).twice.with({'group' => 'default', 'image' => 'ami-123', 'type' => 't1.tiny'})
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    end
    #it 'will fail if a node contains multiple hashes' do
    #  node = {
    #    'nodes' => [
    #      {
    #        'node_one' => {
    #          'create' => { 'options' => {
    #            'group' => 'default',
    #            'image' => 'ami-123',
    #          }}
    #        },
    #        'node_two' => {
    #          'create' => { 'options' => {
    #            'group' => 'default',
    #            'image' => 'ami-123',
    #          }}
    #        }
    #      }
    #    ]
    #  }
    #  write_node_hash(node)
    #  expect do
    #    Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
    #  end.should raise_error(Puppet::Error, /Each node element should be composed of a single hash/)
    #end
    describe 'when installing' do
      before :each do
        Puppet::Stack.expects(:script_file_name).returns('foo')
      end

      let :compiled_template do
        File.join(@stack_dir, 'scripts', 'foo.erb')
      end

      it 'will install puppet on nodes with specified installation instructions' do
        node = {
          'nodes' => [
            'node_one' => {
              'install' => {
                'options' => {
                  'option1' => 'value1'
                }
              }
            }
          ]
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'node_one',
          {'option1' => 'value1', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'will merge default install options' do
        node = {
          'defaults' => {'install' => {'options' => {'default_opt' => 'default'}}},
          'nodes' => [
            'node_one' => {
              'install' => {
                'options' => {
                  'option1' => 'value1'
                }
              }
            }
          ]
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'node_one',
          {'option1' => 'value1', 'install_script' => 'foo', 'default_opt' => 'default'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'will override default install options with node specific ones' do
        node = {
          'defaults' => {'install' => {'options' => {'default_opt' => 'default'}}},
          'nodes' => [
            'node_one' => {
              'install' => {
                'options' => {
                  'default_opt' => 'override'
                }
              }
            }
          ]
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'node_one',
          {'default_opt' => 'override', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'will compile a template to clone a specified git repo' do
        node = {
          'nodes' => [
            'node_one' => {
              'install' => {
                'options' => {
                  'option1' => 'value1',
                },
                'git_repos' => {
                  'git://github.com/p/p' => '/etc/puppet/modules/p'
                },
                'manifest' => '/etc/puppet/modules/swift/examples/all.pp',
              }
            }
          ]
        }
        write_node_hash(node)
        Puppet::Face[:node, :current].expects(:install).with(
          'node_one',
          {'option1' => 'value1', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')

        File.read(compiled_template).split("\n").should include('git clone git://github.com/p/p /etc/puppet/modules/p')
      end
      it 'it should use the hostname of the created instance for installation' do
        node = {'nodes' =>
          ['node_one' =>
            {'create' => { 'options' => {'group' => 'default', 'image' => 'ami-123'}},
             'install' => { 'options' => {'keyfile' => 'foo'}}}
          ]
        }
        write_node_hash(node)
        node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123'}).returns('localhost')
        Puppet::Face[:node, :current].expects(:install).with(
          'localhost',
          {'keyfile' => 'foo', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
    end
    describe 'when specifying a master' do
      describe 'when creating' do
        it 'should create specified masters' do
          node = {
            'master' => {
              'my_master' => {'create' => {'options' => {'group' => 'default', 'image' => 'ami-123'}}}
            }
          }
          write_node_hash(node)
          node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123'})
          Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        end
        it 'should use creation defaults' do
          node = {
            'defaults' => {
              'create' => { 'options' => {
                'type' => 't1.tiny',
              }}
            },
            'master' => {
              'master_one' => {
                'create' => { 'options' => {
                  'group' => 'default', 'image' => 'ami-123'
                }}
               }
             }
          }
          write_node_hash(node)
          node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123', 'type' => 't1.tiny'})
          Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        end
        it 'should use defaults from a config file' do
          File.open(File.join(@puppet_dir, 'stack_builder.yaml'), 'w') do |fh|
            fh.puts <<-EOT
              create:
                options:
                  default_one: file_default
                  default_two: file_default
              install:
                options:
                  default_three: file_default
                  default_four: file_default
            EOT
          end
          node = {
            'defaults' => {
              'create' =>  { 'options' => { 'default_one'   => 'node_default' }},
              'install' => { 'options' => { 'default_three' => 'node_default' }}
            },
            'nodes' => [{
              'node_one' => {
                'create'  => {},
                'install' => {}
              }
            }]
          }

          Puppet::Stack.expects(:script_file_name).returns('foo')

          write_node_hash(node)
          node_face.expects(:create).with(
            {'default_one' => 'node_default', 'default_two' => 'file_default'}
          ).returns('localhost')
          Puppet::Face[:node, :current].expects(:install).with(
            'localhost',
            {
              'default_three' => 'node_default',
              'default_four' => 'file_default',
              'install_script' => 'foo'
            }
          )
          Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        end
        it 'should override creation defaults' do
          node = {
            'defaults' => {
              'create' => { 'options' => {
                'type' => 't1.tiny',
              }}
            },
            'master' => {
              'master_one' => {
                'create' => { 'options' => {
                  'group' => 'default', 'image' => 'ami-123', 'type' => 'm1.small'
                }}
               }
             }
          }
          write_node_hash(node)
          node_face.expects(:create).with({'group' => 'default', 'image' => 'ami-123', 'type' => 'm1.small'})
          Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        end
      end
    end
    describe 'when installing' do
      before :each do
        Puppet::Stack.expects(:script_file_name).at_least_once.returns('foo')
      end

      let :compiled_template do
        File.join(@stack_dir, 'scripts', 'foo.erb')
      end

      it 'should install master' do
        node = {
          'master' => {
            'master_one' => {
              'install' => {
                'options' => {
                  'default_opt' => 'value'
                }
              }
            }
          }
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'master_one',
          {'default_opt' => 'value', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'should use install defaults when installing master' do
        node = {
          'defaults' => {'install' => {'options' => {'default_opt' => 'default'}}},
          'master' => {
            'master_one' => {
              'install' => {}
            }
          }
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'master_one',
          {'default_opt' => 'default', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'should override default installation options with master specific ones' do
        node = {
          'defaults' => {'install' => {'options' => {'default_opt' => 'default'}}},
          'master' => {
            'master_one' => {
              'install' => {
                'options' => {
                  'default_opt' => 'override'
                }
              }
            }
          }
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'master_one',
          {'default_opt' => 'override', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      end
      it 'should compile a template to clone specified git repos' do
        node = {
          'master' => {
            'master_one' => {
              'install' => {
                'options' => {
                  'option1' => 'value1',
                },
                'git_repos' => {
                  'git://github.com/p/p' => '/etc/puppet/modules/p'
                },
                'manifest' => '/etc/puppet/modules/swift/examples/all.pp',
              }
            }
          }
        }
        write_node_hash(node)
        node_face.expects(:create).never
        Puppet::Face[:node, :current].expects(:install).with(
          'master_one',
          {'option1' => 'value1', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        File.read(compiled_template).split("\n").should include('git clone git://github.com/p/p /etc/puppet/modules/p')
      end
      it 'should use the masters returned hostname as the server the agent should connect to' do
        node = {
          'puppet_run_type' => 'agent',
          'master' => {
            'master_one' => {
              'create' => { 'options' => {'foo' => 'bar'}}
            }
          },
          'nodes' =>
          ['node_one' =>
             {'install' => { 'options' => {'keyfile' => 'foo'}}}
          ]
        }
        write_node_hash(node)
        node_face.expects(:create).with({'foo' => 'bar'}).returns('some_hostname')
        Puppet::Face[:node, :current].expects(:install).with(
          'master_one',
          {'option1' => 'value1', 'install_script' => 'foo'}
        ).with(
          'node_one',
          {'keyfile' => 'foo', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        File.read(compiled_template).split("\n").should include('puppet agent --test --certname=node_one --server=some_hostname | tee /tmp/puppet_output.log')

      end
      it 'should use the masters key as the hostname when the master is not created' do
        node = {
          'puppet_run_type' => 'agent',
          'master' => {
            'master_one' => {}
          },
          'nodes' =>
          ['node_one' =>
             {'install' => { 'options' => {'keyfile' => 'foo'}}}
          ]
        }
        write_node_hash(node)
        Puppet::Face[:node, :current].expects(:install).with(
          'node_one',
          {'keyfile' => 'foo', 'install_script' => 'foo'}
        )
        Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
        File.read(compiled_template).split("\n").should include('puppet agent --test --certname=node_one --server=master_one | tee /tmp/puppet_output.log')
      end
    end
  end
  describe 'when terminating' do
    it 'should destory a created master and agent' do
      node = {
        'puppet_run_type' => 'agent',
        # create a single master
        'master' => {
          'master_one' => { 'create' => {}}
        },
        'nodes' =>
        ['node_one' =>
           {'create' => { 'options' => {}}}
        ]
      }
      node_face.expects(:create).twice.with(
        {}
      ).returns('agent').returns('master')
      write_node_hash(node)
      # first create the stack
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      # now test that we can destroy it
      node_face.expects(:terminate).with('master', {'region' => nil})
      node_face.expects(:terminate).with('agent', {'region' => nil})
      Puppet::Stack.destroy({:name => 'dans_stack'})
    end
    it 'should not fail when there is no master to destroy' do
      node = {
        'puppet_run_type' => 'agent',
        # create a single master
        'master' => {
          'master_one' => {}
        },
        'nodes' =>
        ['node_one' =>
           {'create' => { 'options' => {'region' => 'dans-region'}}}
        ]
      }
      node_face.expects(:create).with({'region' => 'dans-region'}).returns('danhost')
      write_node_hash(node)
      # first create the stack
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack2')
      # now test that we can destroy it
      node_face.expects(:terminate).with('danhost', {'region' => 'dans-region'})
      Puppet::Stack.destroy(:name => 'dans_stack2')
    end
    it 'should fail if there are no stacks' do
      expect do
        Puppet::Stack.destroy(:name => 'dans_stack1')
      end.should raise_error(Puppet::Error, /Stack names supplied via --name must have corresponding stack file to be destroyed/)
    end
    it 'should not fail if a stack does not have any created hosts' do
      node = { 'nodes' => ['node_one' => {} ] }
      write_node_hash(node)
      # first create the stack
      Puppet::Stack.build(:config => @tempfile.path, :name => 'dans_stack')
      node_face.expects(:terminate).never
      Puppet::Stack.destroy(:name => 'dans_stack')
    end
  end
  describe 'when listing' do
    it 'should list all stacks' do
      node = { 'nodes' => ['node_one' => {} ] }
      write_node_hash(node)
      node_face.expects(:create).never
      # create multiple stacks
      ['dans_stack1', 'dan_stack2', 'dan_stack3'].each do |s|
        Puppet::Stack.build(:config => @tempfile.path, :name => s)
      end
      Puppet::Stack.list({}).keys.should =~ ['dans_stack1', 'dan_stack2', 'dan_stack3']
    end
    it 'should list no stacks when there are not stacks' do
      Puppet::Stack.list({}).keys.should == []
    end
  end
  describe '#connect' do
    it 'should not connect to anything if a stack is empty'
    it 'should fail with a reasonable error message if tmux is not installed'
    it 'should connect to specified master'
    it 'should connect via key if the node was not created'
  end
end
