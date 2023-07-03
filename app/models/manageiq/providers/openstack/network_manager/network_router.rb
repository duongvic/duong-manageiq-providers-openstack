class ManageIQ::Providers::Openstack::NetworkManager::NetworkRouter < ::NetworkRouter
  include ManageIQ::Providers::Openstack::HelperMethods
  include ProviderObjectMixin
  include AsyncDeleteMixin

  supports :add_interface
  supports :set_gateway
  supports :clear_gateway
  supports :create

  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete, _("The Network Router is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
    if network_ports.any?
      unsupported_reason_add(:delete, _("Unable to delete \"%{name}\" because it has associated ports.") % {
        :name => name
      })
    end
  end

  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update, _("The Network Router is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :set_gateway do
    if ext_management_system.nil?
      unsupported_reason_add(:set_gateway, _("The Network Router is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :clear_gateway do
    if ext_management_system.nil?
      unsupported_reason_add(:clear_gateway, _("The Network Router is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :remove_interface

  def self.raw_create_network_router(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    name = options.delete(:name)
    network_router = nil

    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      network_router = service.create_router(name, options).body
      network_router = network_router['router']
      network_id = network_router.try('external_gateway_info').try('fetch_path', "network_id")
      create(
        :ems_ref => network_router['id'],
        :type => "ManageIQ::Providers::Openstack::NetworkManager::NetworkRouter",
        :ext_management_system => ext_management_system,
        :cloud_tenant => CloudTenant.find_by(:ems_ref => network_router['tenant_id']),
        :evm_owner_id => options[:userid],
        :tenant_id => options[:miq_tenant_id],
        :name => network_router['name'],
        :admin_state_up => network_router['admin_state_up'],
        :status => network_router['status'],
        :external_gateway_info => network_router['external_gateway_info'],
        :distributed => network_router["distributed"],
        :routes => network_router["routes"],
        :high_availability => network_router["ha"],
        :cloud_network => CloudNetwork.find_by(:ems_ref => network_id),
        :cloud_network_id => options[:cloud_network_id],
      )
    end
    { :ems_ref => network_router['id'], :name => network_router['name'] }
  rescue => e
    _log.error "router=[#{options[:name]}], error: #{e}"
    parsed_error = parse_error_message_from_neutron_response(e)
    error_message = case parsed_error
                    when /Quota exceeded for resources/
                      _("Quota exceeded for routers.")
                    else
                      parsed_error
                    end
    raise MiqException::MiqNetworkRouterCreateError, error_message, e.backtrace
  end

  def raw_delete_network_router

    with_notification(:network_router_delete,
                      :options => {
                        :subject => self,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        service.delete_router(ems_ref)
        delete
      end
    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_network_router_queue(userid)
    task_opts = {
      :action => "deleting Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_delete_network_router',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      :args => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_update_network_router(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      options.delete(:external_gateway_info)
      resp = service.update_router(ems_ref, options)
      router = resp.body['router']
      if resp.status == 200
        update(
          :name => router['name']
        )
      end
    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_network_router_queue(userid, options = {})
    task_opts = {
      :action => "updating Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_update_network_router',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      :args => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_set_gateway_network_router(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      resp = service.update_router(ems_ref, options)
      router = resp.body['router']
      subnet_ems_ref = router['external_gateway_info']['external_fixed_ips'][0]['subnet_id']
      subnet = CloudSubnet.find_by(:ems_ref => subnet_ems_ref)
      if resp.status == 200
        update(
          :external_gateway_info => router['external_gateway_info'],
          :cloud_network_id => subnet.cloud_network_id,
        )
        subnet.update(:network_router_id => id)
      end
      # {:router_id => router.id, :ems_id => ext_management_system.id}
    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def set_gateway_network_router_queue(userid, options = {})
    task_opts = {
      :action => "Set Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_set_gateway_network_router',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      :args => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_clear_gateway_network_router(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      # request = options.delete(:external_gateway_info)
      resp = service.update_router(ems_ref, options)
      router = resp.body['router']
      network_router = NetworkRouter.find_by(:ems_ref => router['id'])
      subnet = CloudSubnet.find_by(:cloud_network_id => network_router['cloud_network_id'])
      if resp.status == 200
        update(
          :external_gateway_info => [],
          :cloud_network_id => nil
        )
        subnet.update(:network_router_id => nil)
      end
    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def clear_gateway_network_router_queue(userid, options = {})
    task_opts = {
      :action => "Set Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_clear_gateway_network_router',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      :args => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_sync_load_network_router
    retries = 0
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      begin
        network_router_resp = service.get_router(ems_ref)
        if network_router_resp.status == 200
          body = network_router_resp.body["router"]
          update(
            :external_gateway_info => body["external_gateway_info"],
            :name => body["name"]
          )
          # network = cloud_network.first
          # unless network.nil?
          #
          # end
        end
        raise "Retry syncing"
      rescue => e
        if retries <= 5
          retries += 1
          sleep 5 * retries
          retry
        end
      end
    end
  end

  # def raw_add_interface(cloud_subnet_id, options)
  def raw_add_interface(options)
    cloud_subnet_id = options[:cloud_subnet_id]
    raise ArgumentError, _("Subnet ID cannot be nil") if cloud_subnet_id.nil?
    subnet = CloudSubnet.find(cloud_subnet_id)
    network = CloudNetwork.find(subnet.cloud_network_id);
    raise ArgumentError, _("Subnet cannot be found") if subnet.nil?

    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      cloud_tenant = options[:param_port][:cloud_tenant]
      options.delete(cloud_tenant)

      if options[:fixed_ip] != nil
      #   # ---create new port router interface----
        network_port = service.create_port(network.ems_ref, options[:param_port])
        port = network_port.body['port']
        port_id = port['id']
        unless port.nil?
          router = service.add_router_interface_fixed_ip(ems_ref, port_id)
          if router.status == 200
            create_port_router_interface(ext_management_system, port, cloud_tenant,options )
          elsif
            delete_port(port_id)
          end
        end
      elsif
        router = service.add_router_interface(ems_ref, subnet.ems_ref)
          if router.status == 200
            response_router = router.body
            port_id = response_router['port_id']
            port = service.get_port(port_id).body['port']
            unless port.nil?
              create_port_router_interface(ext_management_system, port, cloud_tenant, options )
            end
          end
      end


      #   # update(:cloud_network_id => subnet.cloud_network_id)
      #   # subnet.update(:network_router_id => id)

    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterAddInterfaceError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def create_port_router_interface(ext_management_system, port, cloud_tenant, options)

    router_id = options[:router_id]
    network_port_new = NetworkPort.new
    network_subnet_port_new = CloudSubnetNetworkPort.new
    other = options[:param_port][:other]
    network_port_new.ems_ref        = port['id']
    network_port_new.ext_management_system  = ext_management_system
    network_port_new.type           = "ManageIQ::Providers::Openstack::NetworkManager::NetworkPort"
    network_port_new.name           = options[:fixed_ip].nil? ? port['mac_address'] :  options[:fixed_ip]
    network_port_new.mac_address    = port['mac_address']
    network_port_new.admin_state_up = port['admin_state_up']
    network_port_new.status         = "ACTIVE"
    network_port_new.device_owner   = "network:router_interface"
    network_port_new.device_ref     = port['device_id']

    # ---id router--
    network_port_new.device_id      = router_id
    # ---------------
    network_port_new.device_type    = "NetworkRouter"
    network_port_new.cloud_tenant   = cloud_tenant
    network_port_new.cloud_tenant_id = cloud_tenant[:id]
    network_port_new.tenant_id      = other[:tenant_id]
    network_port_new.evm_owner_id   = other[:user_id]

    network_port_new.save!

    #-----Create network subnet port---------------
    network_subnet_port_new.cloud_subnet_id = options[:cloud_subnet_id]
    network_subnet_port_new.network_port_id = network_port_new.id
    fixed_ips = port['fixed_ips']
    unless fixed_ips.nil?
      network_subnet_port_new.address = fixed_ips[0]['ip_address']
    end
    network_subnet_port_new.save!
  end

  # def add_interface_queue(userid, cloud_subnet)
    def add_interface_queue(userid, options)
    task_opts = {
      :action => "Adding Interface to Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_add_interface',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      # :args => [cloud_subnet.id]
      :args => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_remove_interface(options)
    cloud_subnet = CloudSubnet.find(options[:cloud_subnet_id]);
    raise ArgumentError, _("Subnet ID cannot be nil") if cloud_subnet.nil?
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      response = service.remove_router_interface(ems_ref, cloud_subnet.ems_ref)
      if response.status == 200
        network_port = NetworkPort.find_by(:device_owner => 'network:router_interface', :device_id => options[:router_id], :ems_ref => response.body['port_id'])
        network_port_id = network_port[:id]
        cloud_subnet_network_port = CloudSubnetNetworkPort.find_by(:network_port_id => network_port_id)
        network_port.delete
        cloud_subnet_network_port.delete
      end
    end
  rescue => e
    _log.error "router=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkRouterRemoveInterfaceError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def remove_interface_queue(userid, options)
    task_opts = {
      :action => "Removing Interface from Network Router for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name => self.class.name,
      :method_name => 'raw_remove_interface',
      :instance_id => id,
      :priority => MiqQueue::HIGH_PRIORITY,
      :role => 'ems_operations',
      :zone => ext_management_system.my_zone,
      # :args => [cloud_subnet.id]
      :args => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = { :service => "Network" }
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def self.display_name(number = 1)
    n_('Network Router (OpenStack)', 'Network Routers (OpenStack)', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
