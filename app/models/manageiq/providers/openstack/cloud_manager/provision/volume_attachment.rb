module ManageIQ::Providers::Openstack::CloudManager::Provision::VolumeAttachment
  def create_requested_volumes(requested_volumes)
    # volumes_attrs_list = [default_volume_attributes]
    volumes_attrs_list = []

    connection_options = {:service => "volume", :tenant_name => cloud_tenant.try(:name)}
    # Forced delete_on_termination onto new volumes so we don't have to have this in the provision menu
    source.ext_management_system.with_provider_connection(connection_options) do |service|
      requested_volumes.each do |volume_attrs|
        volume_attrs[:imageRef] = volume_attrs[:bootable] ? source.ems_ref : nil
        new_volume = service.volumes.create(volume_attrs)
        new_volume_id = new_volume.id
        new_volume_attrs = volume_attrs.clone
        new_volume_attrs[:uuid]                   = new_volume_id
        new_volume_attrs[:bootable]               = volume_attrs[:bootable]
        new_volume_attrs[:source_type]            = 'volume'
        new_volume_attrs[:destination_type]       = 'volume'
        new_volume_attrs[:delete_on_termination]  = true
        volumes_attrs_list << new_volume_attrs
        insert_new_volume(new_volume)
      end
    end
    volumes_attrs_list
  end

  def insert_new_volume(volume)
    attributes = volume.attributes
    new_volume = CloudVolume.new
    new_volume.ems_ref = volume.id
    new_volume.name = volume.name
    new_volume.evm_owner_id = attributes[:evm_owner_id]
    new_volume.type = "ManageIQ::Providers::Openstack::CloudManager::CloudVolume"
    new_volume.tenant = tenant
    new_volume.cloud_tenant = cloud_tenant
    new_volume.ext_management_system = ExtManagementSystem.find_by(:parent_ems_id => source.ext_management_system.id, :type => "ManageIQ::Providers::Openstack::StorageManager::CinderManager")
    new_volume.volume_type = volume.volume_type
    new_volume.size = volume.size.gigabytes
    new_volume.status = 'in-use'
    new_volume.bootable ||= attributes[:bootable] ? attributes[:bootable] : attributes['bootable']
    new_volume.encrypted = attributes['encrypted']
    new_volume.multi_attachment = attributes['multiattach']
    new_volume.save!
  end

  def configure_volumes
    phase_context[:requested_volumes]
  end

  def do_volume_creation_check(volumes_refs)
    connection_options = {:service => "volume", :tenant_name => cloud_tenant.try(:name)}
    source.ext_management_system.with_provider_connection(connection_options) do |service|
      volumes_refs.each do |volume_attrs|
        next unless volume_attrs[:source_type] == "volume"
        volume = service.volumes.get(volume_attrs[:uuid])
        status = volume.try(:status)
        if status == "error"
          raise MiqException::MiqProvisionError, "An error occurred while creating Volume #{volume.name}"
        end
        return false, status unless status == "available"
      end
    end
    true
  end

  def update_volume_bootable_status(volume_id)
    data = {
      "os-set_bootable": {
        "bootable": "True"
      }
    }
    connection_options = {:service => "volume", :tenant_name => cloud_tenant.try(:name)}
    source.ext_management_system.with_provider_connection(connection_options) do |service|
      volume = service.volumes.get(volume_id)
      volume.update_bootable_status(data)
    end
  rescue => e
    raise MiqException::MiqProvisionError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def default_volume_attributes
    {
      :name                  => "root",
      :size                  => instance_type.root_disk_size / 1.gigabyte,
      :source_type           => "image",
      :destination_type      => "local",
      :boot_index            => 0,
      :delete_on_termination => true,
      :uuid                  => source.ems_ref
    }
  end
end
