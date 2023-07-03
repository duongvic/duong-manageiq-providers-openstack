class ManageIQ::Providers::Openstack::Inventory::Parser::StorageManager::CinderManager < ManageIQ::Providers::Openstack::Inventory::Parser
  include ManageIQ::Providers::Openstack::HelperMethods

  def parse
    cloud_volumes
    cloud_volume_snapshots
    cloud_volume_backups
    backup_schedules
    cloud_volume_types
  end

  def cloud_volumes
    collector.cloud_volumes.each do |v|
      volume = persister.cloud_volumes.find_or_build(v.id)
      volume.type = "ManageIQ::Providers::Openstack::CloudManager::CloudVolume"
      volume.name = volume_name(v).blank? ? v.id : volume_name(v)
      volume.status = v.status
      volume.bootable = v.attributes['bootable']
      volume.creation_time = v.created_at
      volume.description = volume_description(v)
      volume.volume_type = v.volume_type
      volume.size = v.size.to_i.gigabytes
      volume.encrypted = v.attributes['encrypted']
      volume.multi_attachment = v.attributes['multiattach']
      volume.base_snapshot = persister.cloud_volume_snapshots.lazy_find(v.snapshot_id)
      volume.cloud_tenant = persister.cloud_tenants.lazy_find(v.tenant_id)
      volume.availability_zone = persister.availability_zones.lazy_find(v.availability_zone)

      volume_attachments(volume, v.attachments)
    end
  end

  def cloud_volume_snapshots
    collector.cloud_volume_snapshots.each do |s|
      snapshot = persister.cloud_volume_snapshots.find_or_build(s['id'])
      snapshot.type = "ManageIQ::Providers::Openstack::CloudManager::CloudVolumeSnapshot"
      snapshot.creation_time = s['created_at']
      snapshot.status = s['status']
      snapshot.size = s['size'].to_i.gigabytes
      # Supporting both Cinder v1 and Cinder v2
      snapshot.name = s['display_name'] || s['name']
      snapshot.description = s['display_description'] || s['description']
      snapshot.cloud_volume = persister.cloud_volumes.lazy_find(s['volume_id'])
      snapshot.cloud_tenant = persister.cloud_tenants.lazy_find(s['os-extended-snapshot-attributes:project_id'])
    end
  end

  def cloud_volume_backups
    collector.cloud_volume_backups.each do |b|
      next b if CloudVolume.find_by(:ems_ref => b['volume']).nil?

      backup = persister.cloud_volume_backups.find_or_build(b['id'])
      backup.type = "ManageIQ::Providers::Openstack::CloudManager::CloudVolumeBackup"
      backup.cloud_volume = CloudVolume.find_by(:ems_ref => b['volume'])
      backup.size = b['size']
      backup.expiration = b['expired_at']

      case b['status']
      when 1
        backup.status = 'PENDING'
      when 2
        backup.status = 'CREATED'
      when 3
        backup.status = 'FAILED'
      end

      backup.creation_time = b['created_at']
      backup.evm_owner = backup.cloud_volume.evm_owner
      backup.tenant = backup.cloud_volume.tenant
    end
  end

  def backup_schedules
    collector.backup_schedules.each do |s|
      next s if CloudVolume.find_by(:ems_ref => s['volume_id']).nil?

      schedule = persister.backup_schedules.find_or_build(s['id'])
      schedule.type = "ManageIQ::Providers::Openstack::CloudManager::BackupSchedule"
      schedule.cloud_volume = CloudVolume.find_by(:ems_ref => s['volume_id'])
      schedule.name = s['name']
      schedule.backup_days = s['days_of_week'].split(',')
      schedule.retention = s['retention']
      schedule.default_retention = s['retention'] == -1
      schedule.start_time = s['start_time']
      schedule.mode = s['mode']
      schedule.evm_owner = schedule.cloud_volume.evm_owner
      schedule.tenant = schedule.cloud_volume.tenant
    end
  end

  def cloud_volume_types
    collector.cloud_volume_types.each do |t|
      volume_type = persister.cloud_volume_types.find_or_build(t.id)
      volume_type.type = "ManageIQ::Providers::Openstack::CloudManager::CloudVolumeType"
      volume_type.name = t.name
      if t.extra_specs.present?
        volume_type.backend_name = t.extra_specs["volume_backend_name"]
      end
      volume_type.description = t.attributes["description"]
      volume_type.public = t.attributes["is_public"]
    end
  end

  def volume_attachments(persister_volume, attachments)
    (attachments || []).each do |a|
      if a['device'].blank?
        log_header = "MIQ(#{self.class.name}.#{__method__}) Collecting data for EMS name: [#{ems.name}] id: [#{ems.id}]"
        _log.warn("#{log_header}: Volume: #{persister_volume.ems_ref}, is missing a mountpoint, skipping the volume processing")
        _log.warn("#{log_header}: EMS: #{ems.name}, Instance: #{a['server_id']}")
        next
      end

      dev = File.basename(a['device'])

      attachment_names = {'vda' => 'Root disk', 'vdb' => 'Ephemeral disk', 'vdc' => 'Swap disk'}
      hardware = persister.hardwares.lazy_find(persister.vms.lazy_find(a["server_id"]))
      persister.disks.find_or_build_by(
        :hardware    => hardware,
        :device_name => attachment_names.fetch(dev, dev)
      ).assign_attributes(
        :location        => dev,
        :size            => persister_volume.size,
        :device_type     => "disk",
        :controller_type => "openstack",
        :backing         => persister_volume
      )
      vm = VmCloud.find_by(:ems_ref => a["server_id"], :template => false)
      unless vm.nil?
        persister_volume.evm_owner = vm.evm_owner
        persister_volume.tenant = vm.tenant
      end
    end
  end

  def volume_name(volume)
    # Cinder v1 : Cinder v2
    volume.respond_to?(:display_name) ? volume.display_name : volume.name
  end

  def volume_description(volume)
    # Cinder v1 : Cinder v2
    volume.respond_to?(:display_description) ? volume.display_description : volume.description
  end
end
