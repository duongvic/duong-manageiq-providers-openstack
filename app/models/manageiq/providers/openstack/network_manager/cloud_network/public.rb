class ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork::Public < ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork
  def self.display_name(number = 1)
    n_('External Network (OpenStack)', 'External Networks (OpenStack)', number)
  end
end
