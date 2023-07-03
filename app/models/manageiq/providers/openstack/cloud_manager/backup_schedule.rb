class ManageIQ::Providers::Openstack::CloudManager::BackupSchedule < ::BackupSchedule
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :create
  supports :delete
  supports :update

  def self.create_schedule(volume, options = {})
    create(
      :name                     => options['name'],
      :type                     => "ManageIQ::Providers::Openstack::CloudManager::BackupSchedule",
      :backup_days              => options['days_of_week'],
      :retention                => options['retention'],
      :default_retention        => options['retention'] == -1,
      :start_time               => options['start_time'],
      :mode                     => options['mode'],
      :ems_ref                  => options['id'],
      :cloud_volume             => volume,
      :ext_management_system    => volume.ext_management_system,
      :evm_owner                => volume.evm_owner,
      :tenant                   => volume.tenant
    )
  end

  def raw_schedule_create(options)
    volume = CloudVolume.find_by(:ems_ref => options[:volume_id])
    schedule_opts = options[:schedule_job]

    with_notification(:backup_schedule_create,
                      :options => {
                        :subject     => self,
                        :schedule_name => options[:name]
                      }) do
      with_benji_connection do |service|
        schedule = service.schedule_job.create(volume_id = options[:volume_id],
                                               name = options[:schedule_name],
                                               mode = schedule_opts[:mode],
                                               days_of_week = schedule_opts[:days_of_week],
                                               start_time = schedule_opts[:start_time],
                                               storage_name = options[:storage_name],
                                               retention = schedule_opts[:retention])
        create_schedule(volume, schedule)
      end
    end
  rescue => e
    _log.error "backup_schedule=[#{name}], error: #{e}"
    raise MiqException::Error, _("Error creating Backup Schedule #{name}"), e.backtrace
  end

  def raw_schedule_delete
    with_notification(:backup_schedule_delete,
                      :options => {
                        :schedule_name => name,
                      }) do
      with_benji_connection do |service|
        service.schedule_job.delete(ems_ref)
        delete
      end
    end
  rescue => e
    _log.error "backup_schedule=[#{name}], error: #{e}"
    raise MiqException::Error, _("Error deleting Backup Schedule #{name}"), e.backtrace
  end

  def raw_schedule_update(options = {})
    db_opts = options.except(:miq_task_id, :task_id)
    schedule_opts = options.except(:id, :default_retention, :ems_id, :miq_task_id, :task_id)
    schedule_opts[:days_of_week] = schedule_opts.delete(:backup_days)

    with_notification(:backup_schedule_update,
                      :options => {
                        :schedule_name => options[:name],
                      }) do
      with_benji_connection do |service|
        service.schedule_job.update(ems_ref, schedule_opts)
        self.update!(self.attributes.merge!(db_opts.stringify_keys))
      end
    end
  rescue => e
    _log.error "backup_schedule=[#{name}], error: #{e}"
    raise MiqException::Error, _("Error updating Backup Schedule #{name}"), e.backtrace
  end

  def schedule_update_queue(userid, options = {})
    task_opts = {
      :action => "updating Backup Schedule for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'raw_schedule_update',
      :instance_id => id,
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def with_benji_connection
    yield Benji::Client.client(url=Rails.application.config.backup_url)
  end
end
