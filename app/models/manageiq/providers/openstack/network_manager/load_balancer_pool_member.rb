class ManageIQ::Providers::Openstack::NetworkManager::LoadBalancerPoolMember < ::LoadBalancerPoolMember
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin
end
