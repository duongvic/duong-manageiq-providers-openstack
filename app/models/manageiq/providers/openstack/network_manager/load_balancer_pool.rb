class ManageIQ::Providers::Openstack::NetworkManager::LoadBalancerPool < ::LoadBalancerPool
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin
end
