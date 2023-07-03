class ManageIQ::Providers::Openstack::NetworkManager::LoadBalancer < ::LoadBalancer
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :create

  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete_load_balancer, _("The Load Balancer is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update_load_balancer, _("The Load Balancer is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  def self.raw_create_load_balancer(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      request_created_lb = options[:load_balancer]
      vip_subnet_id = request_created_lb[:subnet_ems_ref]
      request_created_lb.delete(:subnet_ems_ref)
      load_balancer = service.create_lbaas_loadbalancer(vip_subnet_id, request_created_lb).body
      load_balancer = load_balancer['loadbalancer']
      lb = create(
        :ems_ref => load_balancer['id'],
        :evm_owner => User.find_by(:userid => options[:userid]),
        :tenant => Tenant.find(options[:miq_tenant_id]),
        :name => load_balancer['name'],
        :description => load_balancer['description'],
        :vip_address => load_balancer['vip_address'],
        :operating_status => load_balancer['operating_status'],
        :provisioning_status => load_balancer['provisioning_status'],
        :type => "ManageIQ::Providers::Openstack::NetworkManager::LoadBalancer",
        :ext_management_system => ext_management_system,
        :cloud_tenant => CloudTenant.find_by(:ems_ref => load_balancer['tenant_id'])
      )
      insert_lb_listeners(lb, load_balancer['listeners'], load_balancer['pools']) unless load_balancer['listeners'].empty?
      {:lb_id => lb.id, :ems_id => ext_management_system.id}
    end
  rescue => e
    _log.error "load_balancer=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqLoadBalancerProvisionError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def self.insert_lb_listeners(lb, fog_lb_listeners, fog_lb_pools)
    fog_lb_listeners.each do |listener|
      lb_listener = LoadBalancerListener.new
      lb_listener.name = listener['name']
      lb_listener.description = listener['description']
      lb_listener.ems_ref = listener['id']
      lb_listener.cloud_tenant = lb.cloud_tenant
      lb_listener.ext_management_system = lb.ext_management_system
      lb_listener.load_balancer = lb
      lb_listener.load_balancer_protocol = listener['protocol']
      lb_listener.load_balancer_port_range = (listener['protocol_port']..listener['protocol_port'])
      lb_listener.instance_protocol = listener['protocol']
      lb_listener.instance_port_range = (listener['protocol_port']..listener['protocol_port'])
      lb_listener.connection_limit = listener['connection_limit']
      lb_listener.operating_status = listener['operating_status']
      lb_listener.provisioning_status = listener['provisioning_status']

      if lb_listener.valid? && lb_listener.save!
        insert_lb_pools(lb_listener, fog_lb_pools) unless fog_lb_pools.empty?
      end
    end
  end

  def self.insert_lb_pools(lb_listener, fog_lb_pools)
    fog_lb_pools.each do |pool|
      lb_pool = LoadBalancerPool.new
      lb_pool.name = pool['name']
      lb_pool.description = pool['description']
      # lb_pool.type = "ManageIQ::Providers::Openstack::NetworkManager::LoadBalancerPool"
      lb_pool.ext_management_system = lb_listener.ext_management_system
      lb_pool.cloud_tenant = lb_listener.cloud_tenant
      lb_pool.ems_ref = pool['id']
      lb_pool.load_balancer_algorithm = pool['lb_algorithm']
      lb_pool.protocol = pool['protocol']
      lb_pool.operating_status = pool['operating_status']
      lb_pool.provisioning_status = pool['provisioning_status']
      lb_pool.provisioning_status = pool['provisioning_status']

      if lb_pool.valid? && lb_pool.save!
        insert_pool_member(lb_pool, pool['members']) unless pool['members'].empty?
        insert_health_monitor(lb_pool, pool['healthmonitor']) unless pool['healthmonitor'].nil?
      end

      lb_listener_pool = LoadBalancerListenerPool.new
      lb_listener_pool.load_balancer_listener = lb_listener
      lb_listener_pool.load_balancer_pool_id = lb_pool.id
      lb_listener_pool.save!
    end
  end

  def self.insert_pool_member(pool, fog_pool_members=[])
    fog_pool_members.each do |member|
      pool_member = LoadBalancerPoolMember.new
      pool_member.ext_management_system = pool.ext_management_system
      pool_member.cloud_tenant = pool.cloud_tenant
      pool_member.ems_ref = member['id']
      pool_member.address = member['address']
      pool_member.port = member['protocol_port']
      pool_member.cloud_subnet = CloudSubnet.find_by(:ems_ref => member['subnet_id'])
      pool_member.weight = member['weight']
      pool_member.vm = nil
      pool_member.save!

      pool_member_pool = LoadBalancerPoolMemberPool.new
      pool_member_pool.load_balancer_pool = pool
      pool_member_pool.load_balancer_pool_member_id = pool_member.id
      pool_member_pool.save!
    end
  end

  def self.insert_health_monitor(pool, fog_health_monitor={})
    health_monitor = LoadBalancerHealthCheck.new
    health_monitor.ext_management_system = pool.ext_management_system
    health_monitor.cloud_tenant = pool.cloud_tenant
    health_monitor.load_balancer_listener = pool.load_balancer_listener
    health_monitor.load_balancer = pool.load_balancer_listener.load_balancer
    health_monitor.ems_ref = fog_health_monitor['id']
    health_monitor.name = fog_health_monitor['name']
    health_monitor.protocol = pool.protocol
    # health_monitor.port = fog_health_monitor['port']
    health_monitor.url_path = fog_health_monitor['url_path']
    health_monitor.interval = fog_health_monitor['delay']
    health_monitor.timeout = fog_health_monitor['timeout']
    health_monitor.healthy_threshold = fog_health_monitor['max_retries']
    health_monitor.unhealthy_threshold = fog_health_monitor['max_retries_down']
    health_monitor.save!
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = {:service => "Octavia"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def raw_update_load_balancer(options)
    lb_update = options.except(:task_id, :miq_task_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      resp = service.update_lbaas_loadbalancer(ems_ref, lb_update)
      load_balancer = resp.body
      lb = load_balancer['loadbalancer']
      lb_update = {
        :name => lb['name'],
        :description => lb['description']
      }
      if resp.status == 200
        update!(lb_update)
      end
    end
  rescue => e
    _log.error "load_balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_load_balancer_queue(userid, options = {})
    task_opts = {
      :action => "updating Load Balancer for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_load_balancer',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_sync_load_balancer
    retries = 0
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      begin
        lb_resp = service.get_lbaas_loadbalancer(ems_ref)
        if lb_resp.status == 200
          body = lb_resp.body["loadbalancer"]
          provisioning_status = body["provisioning_status"]
          if provisioning_status == "ACTIVE"
            update(:provisioning_status => provisioning_status, :operating_status => body["operating_status"])
            listener = load_balancer_listeners.first
            unless listener.nil?
              listener_resp = service.get_lbaas_listener(listener.ems_ref)
              if listener_resp.status == 200
                body = listener_resp.body["listener"]
                listener.update(:provisioning_status => body["provisioning_status"], :operating_status => body["operating_status"])
              end

              pool = listener.load_balancer_pools.first
              unless pool.nil?
                pool_resp = service.get_lbaas_pool(pool.ems_ref)
                if pool_resp.status == 200
                  body = pool_resp.body["pool"]
                  pool.update(:provisioning_status => body["provisioning_status"], :operating_status => body["operating_status"])
                end
              end
            end
            return
          end
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

  def raw_delete_load_balancer
    with_notification(:load_balancer_delete,
                      :options => {
                        :subject => self,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        resp = service.delete_lbaas_loadbalancer(ems_ref)
        if resp.status == 204
          destroy
        end
      end
    end
  rescue => e
    _log.error "Load Balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerDeleteError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def raw_update_load_balancer_listener(options)
    listener_opts = options.except(:task_id, :miq_task_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      listener_update = service.update_lbaas_listener(listener_opts[:ems_ref], listener_opts)
      if listener_update.status == 200
        LoadBalancerListener.find_by(:ems_ref => listener_opts[:ems_ref]).update!(listener_opts)
      end
    end
  rescue => e
    _log.error "Load Balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_load_balancer_pool(options)
    pool_opts = options.except(:members, :task_id, :miq_task_id)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      pool_update = service.update_lbaas_pool(pool_opts[:ems_ref], pool_opts)
      if pool_update.status == 200
        LoadBalancerPool.find_by(:ems_ref => pool_opts[:ems_ref]).update!(pool_opts)
      end
    end
  rescue => e
    _log.error "Load Balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_add_load_balancer_pool_member(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      new_member = service.create_lbaas_pool_member(options[:pool_id], options[:address], options[:protocol_port], options.slice(:weight, :subnet_id)).body
      new_member = new_member['member']

      pool_member = LoadBalancerPoolMember.new
      pool_member.type = "ManageIQ::Providers::Openstack::NetworkManager::LoadBalancerPoolMember"
      pool_member.ext_management_system = ext_management_system
      pool_member.cloud_tenant = CloudTenant.find_by(:ems_ref => new_member['tenant_id'])
      pool_member.ems_ref = new_member['id']
      pool_member.address = new_member['address']
      pool_member.port = new_member['protocol_port']
      pool_member.cloud_subnet = CloudSubnet.find_by(:ems_ref => new_member['subnet_id'])
      pool_member.weight = new_member['weight']
      pool_member.vm = nil
      pool_member.save!

      pool_member_pool = LoadBalancerPoolMemberPool.new
      pool_member_pool.load_balancer_pool = LoadBalancerPool.find_by(:ems_ref => options[:pool_id])
      pool_member_pool.load_balancer_pool_member = pool_member
      pool_member_pool.save!
    end
  rescue => e
    _log.error "Load Balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_load_balancer_pool_member(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      resp = service.delete_lbaas_pool_member(options[:pool_id], options[:ems_ref])
      if resp.status == 204
        pool_member = LoadBalancerPoolMember.find_by(:ems_ref => options[:ems_ref])
        pool_member.delete
        LoadBalancerPoolMemberPool.find_by(:load_balancer_pool_member_id => pool_member.id).delete
      end
    end
  rescue => e
    _log.error "Load Balancer=[#{name}], error: #{e}"
    raise MiqException::MiqLoadBalancerUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def self.display_name(number = 1)
    n_('Load Balancers', 'Load Balancers', number)
  end

  private

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
