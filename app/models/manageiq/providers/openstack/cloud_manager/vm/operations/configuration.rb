module ManageIQ::Providers::Openstack::CloudManager::Vm::Operations::Configuration
  extend ActiveSupport::Concern

  def raw_attach_volume(volume_id, device = nil)
    raise _("VM has no EMS, unable to attach volume") unless ext_management_system

    run_command_via_parent(:vm_attach_volume, :volume_id => volume_id, :device => device)
  end

  def raw_detach_volume(volume_id)
    raise _("VM has no EMS, unable to detach volume") unless ext_management_system

    run_command_via_parent(:vm_detach_volume, :volume_id => volume_id)
  end

  def raw_change_admin_password(server_id, options)
    raise _("VM has no EMS, unable to change Admin Password") unless ext_management_system

    run_command_via_parent(:vm_change_admin_password, :server_ems_ref => server_id, :options => options)
  end
end
