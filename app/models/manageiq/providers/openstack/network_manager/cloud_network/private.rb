class ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork::Private < ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork
  def self.display_name(number = 1)
    n_('Network (OpenStack)', 'Networks (OpenStack)', number)
  end
end
