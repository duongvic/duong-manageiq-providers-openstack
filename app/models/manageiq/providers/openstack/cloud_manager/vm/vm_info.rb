module ManageIQ::Providers::Openstack::CloudManager::Vm::VmInfo
  extend ActiveSupport::Concern

  included do
    supports :change_admin_password do
      unsupported_reason_add(:change_admin_password, unsupported_reason(:control)) unless supports_control?
      unless %w(ACTIVE SHUTOFF).include?(raw_power_state)
        unsupported_reason_add(:change_admin_password, _("The Instance Admin Password cannot be changed, current state has to be active or shutoff."))
      end
    end
  end

  def change_vm_name_queue(userid, ems_ref, name)
    task_opts = {
      :action => "changing vm name of #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_change_vm_name',
      :instance_id => id,
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => [ems_ref, name]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_change_vm_name(ems_ref, name)
    target_vm = Vm.find_by(:ems_ref => ems_ref)
    with_notification(:vm_cloud_change_vm_name,
                      :options => {
                        :subject => self
                      }) do
      options = {
        :name => name
      }
      ext_management_system.with_provider_connection(connection_options) do |service|
        service.update_server(ems_ref, options)
      end
    end
  rescue => e
    _log.error "vm=[#{target_vm.name}], error: #{e}"
    raise MiqException::Error, parse_error_message_from_fog_response(e), e.backtrace
  end

  def change_admin_password_queue(userid, server_ems_ref, admin_password)
    task_opts = {
      :action => "changing admin password for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_change_admin_password',
      :instance_id => id,
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => [server_ems_ref, admin_password]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_change_admin_password(server_ems_ref, admin_password)
    target_vm = Vm.find_by(:ems_ref => server_ems_ref)
    with_notification(:vm_cloud_change_admin_password,
                      :options => {
                        :subject => self
                      }) do
      ext_management_system.with_provider_connection(connection_options) do |service|
        service.change_server_password(server_ems_ref, admin_password)
      end
    end
  rescue => e
    _log.error "vm=[#{target_vm.name}], error: #{e}"
    raise MiqException::Error, parse_error_message_from_fog_response(e), e.backtrace
  end
end
