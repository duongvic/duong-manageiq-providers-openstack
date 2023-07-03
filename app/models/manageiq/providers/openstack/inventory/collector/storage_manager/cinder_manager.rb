class ManageIQ::Providers::Openstack::Inventory::Collector::StorageManager::CinderManager < ManageIQ::Providers::Openstack::Inventory::Collector
  include ManageIQ::Providers::Openstack::Inventory::Collector::HelperMethods
  include ManageIQ::Providers::Openstack::HelperMethods

  def cloud_volumes
    return [] unless volume_service
    return @cloud_volumes if @cloud_volumes.any?
    @cloud_volumes = volume_service.handled_list(:volumes, {}, cinder_admin?)
  end

  def cloud_volume_snapshots
    return [] unless volume_service
    return @cloud_volume_snapshots if @cloud_volume_snapshots.any?
    @cloud_volume_snapshots = volume_service.handled_list(:list_snapshots_detailed, {:__request_body_index => "snapshots"}, cinder_admin?)
  end

  def cloud_volume_backups
    # return [] unless volume_service
    # return @cloud_volume_backups if @cloud_volume_backups.any?
    # @cloud_volume_backups = volume_service.handled_list(:list_backups_detailed, {:__request_body_index => "backups"}, cinder_admin?)

    return @cloud_volume_backups if @cloud_volume_backups.any?
    options = {}
    options[:url] = Rails.application.config.backup_url
    with_benji_connection(options) do |service|
      page = 1
      backup_data = service.backup.list({}, page, 100)
      @cloud_volume_backups = backup_data['data']
      until backup_data['next_page'].nil?
        page += 1
        backup_data = service.backup.list({}, page, 100)
        @cloud_volume_backups += backup_data['data']
      end
      @cloud_volume_backups
    end
  end

  def backup_schedules
    return @backup_schedules if @backup_schedules.any?
    options = {}
    options[:url] = Rails.application.config.backup_url
    with_benji_connection(options) do |service|
      page = 1
      schedule_data = service.schedule_job.list({}, page, 100)
      @backup_schedules = schedule_data['data']
      until schedule_data['next_page'].nil?
        page += 1
        schedule_data = service.schedule_job.list({}, page, 100)
        @backup_schedules += schedule_data['data']
      end
      @backup_schedules
    end
  end

  def cloud_volume_types
    return [] unless volume_service
    return @cloud_volume_types if @cloud_volume_types.any?
    @cloud_volume_types = volume_service.handled_list(:volume_types, {}, cinder_admin?)
  end
end
