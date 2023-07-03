class ManageIQ::Providers::Openstack::NetworkManager::NetworkPort < ::NetworkPort
  include ManageIQ::Providers::Openstack::HelperMethods
  include ProviderObjectMixin
  include SupportsFeatureMixin
  def disconnect_port
    # Some ports link subnets to routers, so
    # sever that association if the port is removed
    cloud_subnets.each do |subnet|
      subnet.network_router = nil
      subnet.save!
    end
    delete
  end

  def self.display_name(number = 1)
    n_('Network Port (OpenStack)', 'Network Ports (OpenStack)', number)
  end

  def self.raw_create_network_port(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    network_id =  options.delete(:network_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      network_port = service.create_port(network_id, options)
      body = network_port.body
      unless body.nil?
        port = body['port']
        other = options[:other]
        new_port = create(
          :ems_ref => port['id'],
          :ext_management_system => ext_management_system,
          :type => "ManageIQ::Providers::Openstack::NetworkManager::NetworkPort",
          :name => port['name'],
          :mac_address => port['mac_address'],
          :admin_state_up => port['admin_state_up'],
          :status => port['status'],
          :device_ref => "",
          :device_type => "VmOrTemplate",
          :cloud_tenant => cloud_tenant,
          :tenant_id => other[:tenant_id],
          :evm_owner_id => other[:user_id]
        )

        network_subnet_port = CloudSubnetNetworkPort.new
        network_subnet_port.cloud_subnet_id = other[:subnet_id]
        network_subnet_port.network_port_id = new_port.id
        fixed_ips = port['fixed_ips']
        unless fixed_ips.nil?
          network_subnet_port.address = fixed_ips[0]['ip_address']
        end
        network_subnet_port.save!
      end
    end
  rescue => e
    _log.error "port=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkPortNotDefinedError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_network_port(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_port(ems_ref, options)
    end
  rescue => e
    _log.error "port=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkPortNotDefinedError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_network_port_queue(userid, options={})
    task_opts = {
      :action => "Updating Network Port for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_network_port',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_delete_network_port(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_port(ems_ref)
      destroy
    end
  rescue => e
    _log.error "port=[#{name}], error: #{e}"
    raise MiqException::MiqNetworkPortNotDefinedError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_network_port_queue(userid, options={})
    task_opts = {
      :action => "Deleting Network Port for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_network_port',
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

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end

end
