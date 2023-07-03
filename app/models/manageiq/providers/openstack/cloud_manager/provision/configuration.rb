module ManageIQ::Providers::Openstack::CloudManager::Provision::Configuration
  def associate_floating_ip(ip_address)
    # TODO(lsmola) this should be moved to FloatingIp model
    destination.with_provider_object do |instance|
      instance.associate_address(ip_address.address)
    end
  end

  def configure_network_adapters
    @nics = begin
      networks = Array(options[:networks])
      # CAS(lamps) Create a hash for EACH network chosen to pass into 'networks', which is an array of hashes
      if cloud_network_selection_method == "network" && private_cloud_network
        private_cloud_network.each do |private_net|
          entry_from_dialog = {}
          entry_from_dialog[:private_network_id] = private_net.id
          networks << entry_from_dialog
        end
        if cloud_network_type == true && public_cloud_network
          entry_from_dialog = {}
          entry_from_dialog[:public_network_id] = public_cloud_network.id
          networks << entry_from_dialog
        end
      end
      if cloud_network_selection_method == "port" && network_port
        entry_from_dialog = {}
        entry_from_dialog[:port_id] = network_port.id if cloud_network_selection_method == "port"
        networks << entry_from_dialog
      end
      options[:networks] = convert_networks_to_openstack_nics(networks)
    end
  end

  private

  # CAS(lamps) Each hash should have only 1 key:value pair, and from that we get "net_id" to pass into Fog OpenStack
  # as @nics, or options[:nics] in cloning.rb
  def convert_networks_to_openstack_nics(networks)
    networks.delete_blanks.collect do |nic|
      if nic[:private_network_id]
        {"net_id" => CloudNetwork.find_by(:id => nic[:private_network_id]).ems_ref}
      elsif nic[:public_network_id]
        {"net_id" => CloudNetwork.find_by(:id => nic[:public_network_id]).ems_ref,
         "public" => true}
      elsif nic[:port_id]
        {"port_id" => NetworkPort.find_by(:id => nic[:port_id]).ems_ref}
      end
    end.compact
  end
end
