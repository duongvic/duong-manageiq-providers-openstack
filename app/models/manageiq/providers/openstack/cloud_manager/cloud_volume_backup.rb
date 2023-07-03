class ManageIQ::Providers::Openstack::CloudManager::CloudVolumeBackup < ::CloudVolumeBackup
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :delete
  supports :backup_restore

  def self.create_backup(cloud_volume, backup, options = {})
    create(
      :ems_ref                => backup['id'].to_s,
      :cloud_volume           => cloud_volume,
      :evm_owner              => cloud_volume.evm_owner,
      :name                   => options[:name],
      :type                   => "ManageIQ::Providers::Openstack::CloudManager::CloudVolumeBackup",
      :status                 => 'CREATED',
      :creation_time          => backup['created_at'],
      :size                   => backup['size'].to_i.gigabytes,
      :cloud_tenant           => cloud_volume.cloud_tenant,
      :tenant                 => Tenant.find(options[:miq_tenant_id]),
      :ext_management_system  => cloud_volume.try(:ext_management_system),
    )
  end

  def raw_restore
    with_notification(:cloud_volume_backup_restore,
                      :options => {
                        :subject     => self,
                        :volume_name => self.cloud_volume.name
                      }) do
      with_benji_connection do |service|
        service.backup.restore(ems_ref.to_i)
      end
    end
  rescue => e
    _log.error("backup=[#{name}], error: #{e}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def raw_delete
    with_notification(:cloud_volume_backup_delete,
                      :options => {
                        :subject     => self,
                        :volume_name => self.cloud_volume.name
                      }) do
      with_benji_connection do |service|
        # backup&.destroy
        service.backup.delete(ems_ref.to_i)
        delete
      end
    end
  rescue => e
    _log.error("volume backup=[#{name}], error: #{e}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def raw_create(options = {})
    options[:volume_id] = ems_ref
    with_notification(:cloud_volume_backup_create,
                      :options => {
                        :subject     => self.cloud_volume,
                        :backup_name => options[:name]
                      }) do
      with_benji_connection do |service|
        backup = service.backup.create(volume_id = options[:volume_id], storage_name = options[:storage_name])
        backup
      end
    end
  end

  def backup_restore_queue(userid)
    task_opts = {
      :action => "restoring Cloud Volume from Backup for user #{userid}",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_restore',
      :instance_id => id,
      :role        => 'ems_operations',
      :zone        => ext_management_system.my_zone,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.get_storage_usage(tenant_name)
    options = {}
    options[:storage_name] = tenant_name
    with_benji_connection do |service|
      backup_quotas = service.storage.list(filters = options)
      if backup_quotas['data'].empty?
        return 0
      else
        return backup_quotas['data'][0]['disk_used']
      end
    end
  end

  def with_provider_object
    super(connection_options)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = { :service => 'Volume' }
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def provider_object(connection)
    connection.backups.get(ems_ref)
  end

  def with_provider_connection
    super(connection_options)
  end

  def with_benji_connection
    yield Benji::Client.client(url=Rails.application.config.backup_url)
  end

  private

  def self.with_benji_connection
    yield Benji::Client.client(url=Rails.application.config.backup_url)
  end

  def connection_options
    self.class.connection_options(cloud_tenant)
  end
end
