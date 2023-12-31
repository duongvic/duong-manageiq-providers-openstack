class ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork < ::CloudNetwork
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :create

  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete_cloud_network, _("The Network is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update_cloud_network, _("The Network is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  require_nested :Private
  require_nested :Public

  def self.class_by_ems(ext_management_system, external = false)
    # TODO: A factory on ExtManagementSystem to return class for each provider
    if external
      ext_management_system && ext_management_system.class::CloudNetwork::Public
    else
      ext_management_system && ext_management_system.class::CloudNetwork::Private
    end
  end

  def self.remapping(options)
    new_options = options.dup
    new_options[:router_external] = options[:external_facing] if options[:external_facing]
    new_options.delete(:external_facing)
    new_options
  end

  def self.raw_create_cloud_network(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    raw_options = remapping(options)
    network = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      network = service.networks.new(raw_options)
      network = network.save
      attributes = network.attributes
      status = network.status.to_s.downcase == "active" ? "active" : "inactive"
      network_type_suffix = network.router_external ? "::Public" : "::Private"
      create(
        :ems_ref => network.id,
        :ext_management_system => ext_management_system,
        :evm_owner => User.find_by(:userid => attributes[:userid]),
        :tenant => Tenant.find(attributes[:miq_tenant_id]),
        :type => "ManageIQ::Providers::Openstack::NetworkManager::CloudNetwork#{network_type_suffix}",
        :name => network.name,
        :shared => network.shared,
        :status => status,
        :enabled => network.admin_state_up,
        :external_facing => network.router_external,
        :provider_physical_network => attributes["provider:physical_network"],
        :provider_network_type => attributes["provider:network_type"],
        :provider_segmentation_id => attributes["provider:segmentation_id"],
        :port_security_enabled => attributes["port_security_enabled"],
        :qos_policy_id => attributes["qos_policy_id"],
        :vlan_transparent => attributes["vlan_transparent"],
        :maximum_transmission_unit => attributes["mtu"],
        :cloud_tenant => CloudTenant.find_by(:ems_ref => network.tenant_id),
        )
    end
    {:ems_ref => network.id, :name => options[:name]}
  rescue => e
    _log.error "network=[#{options[:name]}], error: #{e}"
    parsed_error = parse_error_message_from_neutron_response(e)
    raise MiqException::MiqNetworkCreateError, parsed_error, e.backtrace
  end

  def raw_delete_cloud_network
    with_notification(:cloud_network_delete,
                      :options => {
                        :subject => self,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        service.delete_network(ems_ref)
        cloud_subnets.delete_all
        delete
      end
    end
  rescue => e
    _log.error "network=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_cloud_network_queue(userid)
    task_opts = {
      :action => "deleting Network for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_cloud_network',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_update_cloud_network(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      pr_external_facing = options[:external_facing].nil? ? false : options[:external_facing]
      options.delete(:external_facing)

      options[:router_external] = pr_external_facing
      resp = service.update_network(ems_ref, options)
      network = resp.body['network']
      if resp.status == 200
        update(
          :name => network['name'],
          :external_facing => pr_external_facing,
          :enabled => network['admin_state_up']
        )
      end
    end
  rescue => e
    _log.error "network=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_cloud_network_queue(userid, options = {})
    task_opts = {
      :action => "updating Network for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_cloud_network',
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

  def ip_address_total_count
    # TODO(lsmola) Rather storing this in DB? It should be changing only in refresh
    @ip_address_total_count ||= cloud_subnets.all.sum do |subnet|
      # We substract 1 because the first address of the pool is always reserved. For private network it is for DHCP, for
      # public network it's a port for Router.
      subnet.allocation_pools.sum { |x| (IPAddr.new(x["start"])..IPAddr.new(x["end"])).map(&:to_s).count - 1 }
    end
  end

  def ip_address_left_count(reload = false)
    @ip_address_left_count = nil if reload
    @ip_address_left_count ||= ip_address_total_count - ip_address_used_count(reload)
  end

  def ip_address_left_count_live(reload = false)
    @ip_address_left_count_live = nil if reload
    # Live method is asking API drectly for current count of consumed addresses
    @ip_address_left_count_live ||= ip_address_total_count - ip_address_used_count_live(reload)
  end

  def ip_address_used_count(reload = false)
    @ip_address_used_count = nil if reload
    if @public
      # Number of all floating Ips, since we are doing association by creating FloatingIP, because
      # associate is not atomic.
      @ip_address_used_count ||= floating_ips.count
    else
      @ip_address_used_count ||= vms.count
    end
  end

  def ip_address_used_count_live(reload = false)
    @ip_address_used_count_live = nil if reload
    if @public
      # Number of ports with fixed IPs plugged into the network. Live means it talks directly to OpenStack API
      # TODO(lsmola) we probably need paginated API call, there should be no multitenancy needed, but the current
      # UI code allows to mix tenants, so it could be needed, athough netron doesn seem to have --all-tenants calls,
      # so when I use admin, I can see other tenant resources. Investigate, fix.
      @ip_address_used_count_live ||= ext_management_system.with_provider_connection(
        :service     => "Network",
        :tenant_name => cloud_tenant.name
      ) do |connection|
        connection.floating_ips.all(:floating_network_id => ems_ref).count
      end
    else
      @ip_address_used_count_live ||= ext_management_system.with_provider_connection(
        :service     => "Network",
        :tenant_name => cloud_tenant.name
      ) do |connection|
        connection.ports.all(:network_id => ems_ref, :device_owner => "compute:None").count
      end
    end
  end

  def ip_address_utilization(reload = false)
    @ip_address_utilization = nil if reload
    # If total count is 0, utilization should be 100
    @ip_address_utilization ||= begin
      ip_address_total_count > 0 ? (100.0 / ip_address_total_count) * ip_address_used_count(reload) : 100
    end
  end

  def ip_address_utilization_live(reload = false)
    @ip_address_utilization_live = nil if reload
    # Live method is asking API drectly for current count of consumed addresses
    # If total count is 0, utilization should be 100
    @ip_address_utilization_live ||= begin
      ip_address_total_count > 0 ? (100.0 / ip_address_total_count) * ip_address_used_count_live(reload) : 100
    end
  end

  def self.display_name(number = 1)
    n_('Network', 'Networks', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
