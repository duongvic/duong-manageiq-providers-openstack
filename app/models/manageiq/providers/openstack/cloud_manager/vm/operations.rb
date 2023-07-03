module ManageIQ::Providers::Openstack::CloudManager::Vm::Operations
  extend ActiveSupport::Concern

  include_concern 'Configuration'
  include_concern 'Guest'
  include_concern 'Power'
  include_concern 'Relocation'
  include_concern 'Snapshot'

  included do
    supports :terminate do
      unsupported_reason_add(:terminate, unsupported_reason(:control)) unless supports_control?
    end
  end

  def raw_destroy
    raise "VM has no #{ui_lookup(:table => "ext_management_systems")}, unable to destroy VM" unless ext_management_system
    with_notification(:vm_destroy,
                      :options => {
                        :subject => self,
                      }) do
      disks = Disk.where(:hardware_id => self.id)
      disks.each do |disk|
        cloud_volume = CloudVolume.find_by(:id => disk.backing_id)
        cloud_volume.update!(:status => 'available')
        if(cloud_volume.bootable === true)
          cloud_volume.delete
        end
        disk.delete
      end
      with_provider_object(&:destroy)
    end
    self.update!(:raw_power_state => "DELETED")
  end
end
