class ManageIQ::Providers::Openstack::NetworkManager::CloudSubnet < ::CloudSubnet
  include ManageIQ::Providers::Openstack::HelperMethods
  include ProviderObjectMixin
  include SupportsFeatureMixin

  supports :create
  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete, _("The subnet is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
    if number_of(:vms) > 0
      unsupported_reason_add(:delete, _("The subnet has an active %{table}") % {
        :table => ui_lookup(:table => "vm_cloud")
      })
    end
  end
  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update, _("The subnet is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  def self.raw_create_cloud_subnet(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    subnet = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      subnet = service.subnets.new(options)
      subnet = subnet.save
      attributes = subnet.attributes
      cloud_network = CloudNetwork.find_by(:ems_ref => subnet.network_id)
      create(
        :ems_ref => subnet.id,
        :ext_management_system => ext_management_system,
        :type => "ManageIQ::Providers::Openstack::NetworkManager::CloudSubnet",
        :name => subnet.name,
        :cidr => subnet.cidr,
        :network_protocol => "ipv#{subnet.ip_version}",
        :gateway => subnet.gateway_ip,
        :dhcp_enabled => subnet.enable_dhcp,
        :dns_nameservers => subnet.dns_nameservers,
        :ipv6_router_advertisement_mode => attributes["ipv6_ra_mode"],
        :ipv6_address_mode => attributes["ipv6_address_mode"],
        :allocation_pools => subnet.allocation_pools,
        :host_routes => subnet.host_routes,
        :ip_version => subnet.ip_version,
        :evm_owner => User.find_by(:userid => attributes[:userid]),
        :cloud_tenant => CloudTenant.find_by(:ems_ref => subnet.tenant_id),
        :cloud_network => cloud_network,
        :status => cloud_network.status,
      )
    end
    {:ems_ref => subnet.id, :name => subnet.name}
  rescue => e
    _log.error "subnet=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqCloudSubnetCreateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_cloud_subnet
    with_notification(:cloud_subnet_delete,
                      :options => {
                        :subject => self,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        service.delete_subnet(ems_ref)
        delete
      end
    end
  rescue => e
    _log.error "subnet=[#{name}], error: #{e}"
    raise MiqException::MiqCloudSubnetDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_cloud_subnet_queue(userid)
    task_opts = {
      :action => "deleting Subnet for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_cloud_subnet',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_update_cloud_subnet(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_subnet(ems_ref, options)
    end
  rescue => e
    _log.error "subnet=[#{name}], error: #{e}"
    raise MiqException::MiqCloudSubnetUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_cloud_subnet_queue(userid, options = {})
    task_opts = {
      :action => "updating Subnet for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_cloud_subnet',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = {:service => "Network"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def self.display_name(number = 1)
    n_('Subnet', 'Subnets', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
