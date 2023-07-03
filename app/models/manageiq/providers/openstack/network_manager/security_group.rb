class ManageIQ::Providers::Openstack::NetworkManager::SecurityGroup < ::SecurityGroup
  include ManageIQ::Providers::Openstack::HelperMethods

  supports :create

  supports :delete do
    if ext_management_system.nil?
      unsupported_reason_add(:delete_security_group, _("The Security Group is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  supports :update do
    if ext_management_system.nil?
      unsupported_reason_add(:update_security_group, _("The Security Group is not connected to an active %{table}") % {
        :table => ui_lookup(:table => "ext_management_systems")
      })
    end
  end

  def self.parse_security_group_rule(rule)
    if rule["source_security_group_id"] && !rule["source_security_group_id"].empty?
      sg = SecurityGroup.find(rule["source_security_group_id"])
    end
    {
      :ethertype        => rule["network_protocol"].to_s.downcase,
      :port_range_min   => rule["port"],
      :port_range_max   => rule["end_port"],
      :protocol         => rule["host_protocol"].empty? ? nil : rule["host_protocol"].to_s.downcase,
      :remote_group_id  => sg.try(:ems_ref),
      :remote_ip_prefix => rule["source_ip_range"]
    }
  end

  def self.raw_create_security_group(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    security_group = nil
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      security_group = service.create_security_group(options).body
      if security_group
        security_group = security_group['security_group']
        sg_klass = create(
          :ems_ref => security_group['id'],
          :type => "ManageIQ::Providers::Openstack::NetworkManager::SecurityGroup",
          :ext_management_system => ext_management_system,
          :name => security_group['name'],
          :description => security_group['description'].try(:truncate, 255),
          :cloud_tenant => CloudTenant.find_by(:ems_ref => security_group['tenant_id']),
          :evm_owner => User.find_by(:userid => options[:userid]),
          :tenant => Tenant.find(options[:miq_tenant_id]),
          :orchestration_stack => nil,
          )
        security_group['security_group_rules'].each do |r|
          # insert firewall rules
          insert_firewall_rule(r, sg_klass)
        end
      end
    end
    {:ems_ref => security_group['id'], :name => security_group['name']}
  rescue => e
    _log.error "security_group=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqSecurityGroupCreateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_delete_security_group
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_security_group(ems_ref)
      firewall_rules.delete_all
      delete
    end
  rescue => e
    _log.error "security_group=[#{name}], error: #{e}"
    raise MiqException::MiqSecurityGroupDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def delete_security_group_queue(userid)
    task_opts = {
      :action => "deleting Security Group for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_security_group',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def create_security_group_rule_queue(userid, security_group_id, direction, options = {})
    task_opts = {
      :action => "create Security Group rule for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_create_security_group_rule',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [security_group_id, direction, options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_create_security_group_rule(security_group_id, direction, options)
    options.delete_if { |_k, v| v.nil? || v.empty? }
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      created_rule = service.create_security_group_rule(security_group_id, parse_direction(direction), options).body
      self.class.insert_firewall_rule(created_rule['security_group_rule'], self) if created_rule
    end
  rescue => e
    _log.error "security_group=[#{name}], error: #{e}"
    raise MiqException::MiqSecurityGroupCreateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def self.insert_firewall_rule(rule, security_group)
    firewall_rule = FirewallRule.find_or_create_by(:ems_ref => rule['id'])
    firewall_rule.ems_ref = rule['id']
    firewall_rule.resource = security_group
    # firewall_rule.source_security_group = persister.security_groups.lazy_find(collector.security_groups_by_name[rule.group["name"]])
    firewall_rule.network_protocol = rule['ethertype']
    firewall_rule.direction = rule['direction'] == "egress" ? 'outbound' : 'inbound'
    firewall_rule.host_protocol = rule['protocol'].nil? ? 'Any' : rule['protocol'].to_s.upcase.split("-").last
    firewall_rule.port = rule['port_range_min']
    firewall_rule.end_port = rule['port_range_max']
    firewall_rule.source_ip_range = rule['remote_ip_prefix']
    firewall_rule.network_protocol = rule['ethertype'].to_s.upcase
    firewall_rule.save!

    {:ems_ref => firewall_rule.ems_ref, :name => nil}
  end

  def delete_security_group_rule_queue(userid, key)
    task_opts = {
      :action => "delete Security Group rule for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_delete_security_group_rule',
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [key]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_delete_security_group_rule(key)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.delete_security_group_rule(key)
      FirewallRule.where(:ems_ref => key).delete_all
    end
  rescue => e
    _log.error "security_group_rule=[#{key}], error: #{e}"
    raise MiqException::MiqSecurityGroupDeleteError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def raw_update_security_group(options)
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      service.update_security_group(ems_ref, options)
    end
  rescue => e
    _log.error "security_group=[#{name}], error: #{e}"
    raise MiqException::MiqSecurityGroupUpdateError, parse_error_message_from_neutron_response(e), e.backtrace
  end

  def update_security_group_queue(userid, options = {})
    task_opts = {
      :action => "updating Security Group for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_update_security_group',
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
    n_('Security Group (OpenStack)', 'Security Groups (OpenStack)', number)
  end

  private

  def parse_direction(val)
    val == "outbound" ? "egress" : "ingress"
  end

  def connection_options(cloud_tenant = nil)
    self.class.connection_options(cloud_tenant)
  end
end
