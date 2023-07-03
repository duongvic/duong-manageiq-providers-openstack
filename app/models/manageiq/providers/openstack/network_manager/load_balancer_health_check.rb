class ManageIQ::Providers::Openstack::NetworkManager::LoadBalancerHealthCheck < ::LoadBalancerHealthCheck
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin
end
