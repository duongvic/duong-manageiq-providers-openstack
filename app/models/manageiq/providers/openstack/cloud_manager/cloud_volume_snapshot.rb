class ManageIQ::Providers::Openstack::CloudManager::CloudVolumeSnapshot < ::CloudVolumeSnapshot
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :create
  supports :update
  supports :delete
  supports :rollback

  def provider_object(connection)
    connection.snapshots.get(ems_ref)
  end

  def with_provider_object
    super(connection_options)
  end

  def self.create_snapshot_queue(userid, cloud_volume, options = {})
    ext_management_system = cloud_volume.try(:ext_management_system)
    task_opts = {
      :action => "creating volume snapshot in #{ext_management_system.inspect} for #{cloud_volume.inspect} with #{options.inspect}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => cloud_volume.class.name,
      :instance_id => cloud_volume.id,
      :method_name => 'create_volume_snapshot',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone(ext_management_system),
      :args        => [options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.create_snapshot(cloud_volume, options = {})
    raise ArgumentError, _("cloud_volume cannot be nil") if cloud_volume.nil?
    ext_management_system = cloud_volume.try(:ext_management_system)
    raise ArgumentError, _("ext_management_system cannot be nil") if ext_management_system.nil?

    cloud_tenant = cloud_volume.cloud_tenant
    snapshot = nil
    options[:volume_id] = cloud_volume.ems_ref
    options[:force] = true
    with_notification(:cloud_volume_snapshot_create,
                      :options => {
                        :snapshot_name => options[:name],
                        :volume_name   => cloud_volume.name,
                        :force => true,
                      }) do
      ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
        snapshot = service.snapshots.create(options)
      end
    end

    create(
      :name                  => snapshot.name,
      :description           => snapshot.description,
      :ems_ref               => snapshot.id,
      :size                  => snapshot.size.gigabytes,
      :status                => 'created',
      :cloud_volume          => cloud_volume,
      :cloud_tenant          => cloud_tenant,
      :evm_owner             => cloud_volume.evm_owner,
      :tenant                => cloud_volume.tenant,
      :ext_management_system => ext_management_system,
    )

    # ManageIQ::Providers::Openstack::CloudManager::VolumeSnapshotTemplate.create(
    #   :name => snapshot.name,
    #   :type => "ManageIQ::Providers::Openstack::CloudManager::VolumeSnapshotTemplate",
    #   :ems_ref => snapshot.ems_ref,
    #   :template => true,
    #   :location => "N/A",
    #   :vendor => "openstack",
    #   :cloud_tenant => cloud_tenant,
    #   :raw_power_state => "never",
    #   :evm_owner => cloud_volume.evm_owner,
    #   :miq_group_id => cloud_volume.evm_owner.current_group_id,
    #   :tenant => cloud_volume.tenant,
    #   :ems_id => ext_management_system.parent_ems_id,
    #   :cloud => true,
    #   :publicly_available => false,
    # )
  rescue => e
    _log.error "snapshot=[#{options[:name]}], error: #{e}"
    raise MiqException::MiqVolumeSnapshotCreateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def update_snapshot_queue(userid = "system", options = {})
    task_opts = {
      :action => "updating volume snapshot #{inspect} in #{ext_management_system.inspect} with #{options.inspect}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'update_snapshot',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => [options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def update_snapshot(options = {})
    with_provider_object do |snapshot|
      if snapshot
        snapshot.update(options)
      else
        raise MiqException::MiqVolumeSnapshotUpdateError("snapshot does not exist")
      end
    end
  rescue => e
    _log.error "snapshot=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeSnapshotUpdateError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def delete_snapshot_queue(userid = "system", _options = {})
    task_opts = {
      :action => "deleting volume snapshot #{inspect} in #{ext_management_system.inspect}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'delete_snapshot',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => []
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_snapshot(_options = {})
    with_notification(:cloud_volume_snapshot_delete,
                      :options => {
                        :subject       => self,
                      }) do
      with_provider_object do |snapshot|
        if snapshot
          snapshot.destroy
          delete
        else
          _log.warn("snapshot=[#{name}] already deleted")
        end
      end
    end
  rescue => e
    _log.error "snapshot=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeSnapshotDeleteError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def create_volume_from_snapshot(options = {})
    ManageIQ::Providers::Openstack::CloudManager::CloudVolume.raw_create_volume(ext_management_system, options)
  rescue => e
    _log.error "snapshot=[#{name}], error: #{e}"
    raise MiqException::MiqVolumeSnapshotDeleteError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def create_volume_from_snapshot_queue(userid, ext_management_system, options = {})
    task_opts = {
      :action => "creating volume from snapshot #{inspect} in #{ext_management_system.inspect}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => self.id,
      :method_name => 'create_volume_from_snapshot',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => [options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def rollback_snapshot(_options = {})

    with_notification(:cloud_volume_snapshot_rollback,
                      :options => {
                        :subject       => self,
                        :volume_name   => cloud_volume.name,
                      }) do
      with_ceph_connection do |service|
        image_spec = "volumes/volume-#{cloud_volume.ems_ref}"
        snapshot_name = "snapshot-#{self.ems_ref}"
        service.snapshot.rollback(image_spec, snapshot_name)
      end
    end
  rescue => e
    _log.error "snapshot=[#{name}], error: #{e}"
    raise MiqException::Error, _("An error has occurred while rolling back to snapshot #{name}"), e.backtrace
  end

  def rollback_snapshot_queue(userid = "system", _options = {})
    task_opts = {
      :action => "rolling back volume snapshot #{inspect} in #{ext_management_system.inspect}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => self.id,
      :method_name => 'rollback_snapshot',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => []
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = { :service => 'Volume' }
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  def with_ceph_connection
    yield Ceph::Client.client(url=Rails.application.config.ceph_url,
                              credentials=Rails.application.config.ceph_credentials)
  end

  private

  def connection_options
    self.class.connection_options(cloud_tenant)
  end
end
