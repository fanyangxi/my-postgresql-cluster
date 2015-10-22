# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure(2) do |config|

  # config.vm.box = "chef/centos-6.5"
  config.vm.box = "ubuntu/trusty64"
  config.vm.hostname = "pg-node-3"

  # config.vm.network "forwarded_port", guest: 5432, host: 5432
  config.vm.network "private_network", ip: "192.168.3.13"

  # config.vm.network "public_network"
  # config.vm.synced_folder ".", "/vagrant_data"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "512"
  end
  
  config.vm.provision 'ansible' do |ansible|
    ansible.playbook = 'provision/playbook.yml'
    # ansible.verbose = 'vvv'
  end

  config.vm.provision "shell" do |sh|
    sh.path = "provision/tw-pg-node-slave.sh"
  end

end
