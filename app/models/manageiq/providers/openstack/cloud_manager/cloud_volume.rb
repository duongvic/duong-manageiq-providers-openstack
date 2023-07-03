class ManageIQ::Providers::Openstack::CloudManager::CloudVolume < ::CloudVolume
  include ManageIQ::Providers::Openstack::HelperMethods
  include_concern 'Operations'

  include SupportsFeatureMixin

  supports :create
  supports :backup_create
  supports :backup_restore
  supports :snapshot_create

  def self.validate_create_volume(ext_management_system)
    validate_volume(ext_management_system)
  end

  def self.raw_create_volume(ext_management_system, options)
    cloud_tenant = options.delete(:cloud_tenant)
    volume = nil

    # provide display_name for Cinder V1
    options[:display_name] |= options[:name]
    with_notification(:cloud_volume_create,
                      :options => {
                        :volume_name => options[:name],
                      }) do
      ext_management_system.with_provider_connection(cinder_connection_options(cloud_tenant)) do |service|
        volume = service.volumes.create(options)
        attributes = volume.attributes
        owner = User.find_by(:userid => attributes[:userid])
        tenant = MiqGroup.find(owner.current_group_id).tenant
        create(
          :ems_ref => volume.id,
          :name => volume.name,
          :evm_owner => owner,
          :type => "ManageIQ::Providers::Openstack::CloudManager::CloudVolume",
          :tenant => tenant,
          :cloud_tenant => cloud_tenant,
          :volume_type => volume.volume_type,
          :size => volume.size.gigabytes,
          :status => 'available',
          :ext_management_system =>
            ext_management_system.type == "ManageIQ::Providers::Openstack::StorageManager::CinderManager" ?
              ext_management_system :
              ExtManagementSystem.find_by(:parent_ems_id => ext_management_system.id,
                                          :type => "ManageIQ::Providers::Openstack::StorageManager::CinderManager"),
          :bootable => attributes['bootable'],
          :encrypted => attributes['encrypted'],
          :multi_attachment => attributes['multiattach'],
          :base_snapshot => CloudVolumeSnapshot.find_by(:ems_ref => options[:snapshot_id])
        )
      end
    end
    {:ems_ref => volume.id, :status => volume.status, :name => options[:name]}
  rescue => e
    _log.error "volume=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqVolumeCreateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def validate_update_volume
    validate_volume
  end

  def raw_update_status_volume(options)
    volume = CloudVolume.find_by(:ems_ref => options[:ems_ref])
    status = options[:status_volume]
    ext_management_system.with_provider_connection(cinder_connection_options) do |service|
      response = service.reset_volume(volume.ems_ref, status)
      if response.status == 202
        volume.update(:status => status)
      end
    end
  rescue => e
    _log.error "volume=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeUpdateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def raw_update_volume(options)
    new_size = (options[:size].to_i).gigabytes
    data_volume = CloudVolume.find_by(:ems_ref => options[:ems_ref])
    options.delete(:ems_ref)
    with_notification(:cloud_volume_update,
                      :options => {
                        :subject => self,
                      }) do
      with_provider_object do |volume|
        size = options.delete(:size)
        volume.attributes.merge!(options)
        response_save = volume.save
        if response_save
          data_volume.update(:name => options[:name])
        end
        if size.to_i != volume.size.to_i
          response_extend = volume.extend(size)
          if response_extend
            data_volume.update(:size => new_size,
                               :status => "in-use"
            )
          end
        end
      end
    end
  rescue => e
    _log.error "volume=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeUpdateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def validate_delete_volume
    msg = validate_volume
    return {:available => msg[:available], :message => msg[:message]} unless msg[:available]
    if status == "in-use"
      return validation_failed("Delete Volume", "Can't delete volume that is in use.")
    end
    {:available => true, :message => nil}
  end

  def raw_delete_volume
    with_notification(:cloud_volume_delete,
                      :options => {
                        :subject => self,
                      }) do
      with_provider_object { |volume| volume.try(:destroy) }
      delete
    end
  rescue => e
    _log.error "volume=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeDeleteError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def backup_create(options)
    options[:volume_id] = ems_ref
    schedule_opts = options[:schedule_job]

    with_notification(:cloud_volume_backup_create,
                      :options => {
                        :subject     => self,
                        :backup_name => options[:name]
                      }) do
      with_benji_connection do |service|
        backup = service.backup.create(volume_id = options[:volume_id], storage_name = options[:storage_name])
        unless schedule_opts[:enabled] == "false"
          schedule = service.schedule_job.create(volume_id = options[:volume_id],
                                                 name = schedule_opts[:name],
                                                 mode = schedule_opts[:mode],
                                                 days_of_week = schedule_opts[:days_of_week],
                                                 start_time = schedule_opts[:start_time],
                                                 storage_name = options[:storage_name],
                                                 retention = schedule_opts[:retention])
          ManageIQ::Providers::Openstack::CloudManager::BackupSchedule.create_schedule(self, schedule)
        end
        ManageIQ::Providers::Openstack::CloudManager::CloudVolumeBackup.create_backup(self, backup, options)
      end
    end
  rescue => e
    _log.error "backup=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeBackupCreateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def backup_create_queue(userid, options = {})
    task_opts = {
      :action => "creating Cloud Volume Backup for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'backup_create',
      :instance_id => id,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def backup_restore(backup_id)
    backup = CloudVolumeBackup.find_by(:ems_ref => backup_id)
    with_notification(:cloud_volume_backup_restore,
                      :options => {
                        :subject     => backup,
                        :volume_name => self.name
                      }) do
      with_benji_connection do |service|
        service.backup.restore(backup_id)
      end
    end
  rescue => e
    _log.error "volume=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeBackupRestoreError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def backup_restore_queue(userid, backup_id)
    task_opts = {
      :action => "restoring Cloud Volume from Backup for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'backup_restore',
      :instance_id => id,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => [backup_id]
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def create_volume_snapshot(options)
    ManageIQ::Providers::Openstack::CloudManager::CloudVolumeSnapshot.create_snapshot(self, options)
  end

  def create_volume_snapshot_queue(userid, options)
    ManageIQ::Providers::Openstack::CloudManager::CloudVolumeSnapshot
      .create_snapshot_queue(userid, self, options)
  end

  def available_vms
    cloud_tenant.vms.where.not(:id => vms.select(&:id))
  end

  def provider_object(connection)
    connection.volumes.get(ems_ref)
  end

  def with_provider_object
    super(cinder_connection_options)
  end

  def with_provider_connection
    super(connection_options)
  end

  def with_benji_connection
    yield Benji::Client.client(url=Rails.application.config.backup_url)
  end

  private

  def connection_options
    # TODO(lsmola) expand with cinder connection when we have Cinder v2, based on respond to on service.volumes method,
    #  but best if we can fetch endpoint list and do discovery of available versions
    nova_connection_options
  end

  def nova_connection_options
    connection_options = {:service => "Compute"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options[:proxy] = openstack_proxy if openstack_proxy
    connection_options
  end

  def self.cinder_connection_options(cloud_tenant = nil)
    connection_options = {:service => "Volume"}
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options[:proxy] = openstack_proxy if openstack_proxy
    connection_options
  end

  def cinder_connection_options
    self.class.cinder_connection_options(cloud_tenant)
  end

end
