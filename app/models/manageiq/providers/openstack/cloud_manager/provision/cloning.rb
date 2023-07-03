$LOAD_PATH.unshift(File.join(Rails.root, 'app/grpc/vm')) unless $LOAD_PATH.include?(File.join(Rails.root, 'app/grpc/vm'))
require 'grpc'
require 'vm_services_pb'

module ManageIQ::Providers::Openstack::CloudManager::Provision::Cloning

  def find_destination_in_vmdb(ems_ref)
    super
  rescue NoMethodError => ex
    # TODO: this should not be needed after we update refresh to not disconnect VmOrTemplate from EMS
    _log.debug("Unable to find Provison Source ExtmanagementSystem: #{ex}")
    _log.debug("Trying use attribute src_ems_id=#{options[:src_ems_id].try(:first)} instead.")
    vm_model_class.find_by(:ems_id => options[:src_ems_id].try(:first), :ems_ref => ems_ref)
  end

  def do_clone_task_check(clone_task_ref)
    connection_options = {:tenant_name => cloud_tenant.try(:name)}
    source.with_provider_connection(connection_options) do |openstack|
      instance = if connection_options
                   openstack.servers.get(clone_task_ref)
                 else
                   openstack.handled_list(:servers).detect { |s| s.id == clone_task_ref }
                 end
      status   = instance.state.downcase.to_sym if instance.present?

      if status == :error
        error_message = instance.fault["message"]
        raise MiqException::MiqProvisionError, "An error occurred while provisioning Instance #{instance.name}: #{error_message}"
      end
      return true if status == :active
      return false, status
    end
  end

  def prepare_for_clone_task
    clone_options = super

    clone_options[:name]              = "#{dest_name}"
    clone_options[:image_ref]         = source.ems_ref
    clone_options[:flavor_ref]        = instance_type.ems_ref
    clone_options[:availability_zone] = dest_availability_zone.nil? ? nil : dest_availability_zone.ems_ref
    clone_options[:security_groups]   = security_groups.collect(&:ems_ref)
    clone_options[:nics]              = configure_network_adapters if configure_network_adapters.present?
    clone_options[:userid]            = options[:userid]

    clone_options[:block_device_mapping_v2] = configure_volumes.present? ? configure_volumes : []

    # CAS(lamps) Append selected volumes to block device mapping
    unless selected_volumes.nil?
      selected_volumes&.collect do |volume|
        selected_volume = {}
        selected_volume[:selected] = true
        selected_volume[:bootable] = volume[:bootable]
        selected_volume[:evm_owner_id] = volume.evm_owner_id
        selected_volume[:size] = volume.size.gigabytes
        selected_volume[:name] = volume.name
        selected_volume[:uuid] = volume.ems_ref
        selected_volume[:source_type] = "volume"
        selected_volume[:destination_type] = "volume"

        clone_options[:block_device_mapping_v2] << selected_volume
      end
    end


    linux_cloud_init = "#cloud-config
    disable_root: false
    ssh_pwauth: True
    ssh_deletekeys: False
    chpasswd:
       list: |
         root:#{options[:root_password]}
       expire: False
"

    win_cloud_init = "#ps1
    net user Administrator #{options[:root_password]}
    net user administrator /active:yes
"
    root_pass = source.name.include?("Window") ? win_cloud_init : linux_cloud_init
    clone_options[:user_data_encoded] = Base64.encode64(root_pass)
    clone_options
  end

  def log_clone_options(clone_options)
    _log.info("Provisioning [#{source.name}] to [#{clone_options[:name]}]")
    _log.info("Source Image:                    [#{clone_options[:image_ref]}]")
    _log.info("Destination Availability Zone:   [#{clone_options[:availability_zone]}]")
    _log.info("Flavor:                          [#{clone_options[:flavor_ref]}]")
    _log.info("Guest Access Key Pair:           [#{clone_options[:key_name]}]")
    _log.info("Security Group:                  [#{clone_options[:security_groups]}]")
    _log.info("Network:                         [#{clone_options[:nics]}]")

    dump_obj(clone_options, "#{_log.prefix} Clone Options: ", $log, :info)
    dump_obj(options, "#{_log.prefix} Prov Options:  ", $log, :info, :protected => {:path => workflow_class.encrypted_options_field_regs})
  end

  # dispatches operations to multiple vms
  def add_audit_event(clone_options)
    userid = clone_options[:block_device_mapping_v2][0][:evm_owner_id].nil? ?
               User.current_user.userid :
               User.find(clone_options[:block_device_mapping_v2][0][:evm_owner_id]).userid

    total_size = 0
    clone_options[:block_device_mapping_v2].each do |volume|
      total_size += volume[:size].to_i
    end

    ip_count = clone_options[:nics].count

    vm_data = {
      :name       => clone_options[:name],
      :memory     => instance_type.memory / 1.gigabytes,
      :cpus       => instance_type.cpus.to_i,
      :disk       => total_size,
      :ip_count   => ip_count
    }

    audit = {
      :event        => "vm_record_create_initiated",
      :message      => "VM [#{clone_options[:name]}] created",
      :target_id    => nil,
      :target_class => "Vms",
      :service      => AuditEvent.services[:vm],
      :action       => AuditEvent.actions[:create],
      :data         => vm_data.to_json,
      :userid       => userid
    }
    AuditEvent.success(audit)
  end

  def start_clone(clone_options)
    connection_options = {:tenant_name => cloud_tenant.try(:name)}
    if source.kind_of?(ManageIQ::Providers::Openstack::CloudManager::VolumeTemplate)
      # remove the image_ref parameter from the options since it actually refers
      # to a volume, and then overwrite the default root volume with the volume
      # we are trying to boot the instance from
      clone_options.delete(:image_ref)
      clone_options[:block_device_mapping_v2][0][:source_type] = "volume"
      clone_options[:block_device_mapping_v2][0].delete(:size)
      clone_options[:block_device_mapping_v2][0][:delete_on_termination] = true
      clone_options[:block_device_mapping_v2][0][:destination_type] = "volume"
      # adjust the parameters to make booting from a volume work.

    elsif source.kind_of?(ManageIQ::Providers::Openstack::CloudManager::VolumeSnapshotTemplate)
      # remove the image_ref parameter from the options since it actually refers
      # to a volume, and then overwrite the default root volume with the volume
      # we are trying to boot the instance from
      clone_options.delete(:image_ref)
      clone_options[:block_device_mapping_v2][0][:source_type] = "snapshot"
      clone_options[:block_device_mapping_v2][0].delete(:size)
      clone_options[:block_device_mapping_v2][0][:destination_type] = "volume"

    elsif source.kind_of?(ManageIQ::Providers::Openstack::CloudManager::Template)
      # CAS(lamps) Make sure the bootable volume is selected as boot source
      bootable_vol = clone_options[:block_device_mapping_v2].select {|vol| vol[:bootable] == true}.first
      clone_options.delete(:image_ref)
      if bootable_vol.nil?
        bootable_vol = clone_options[:block_device_mapping_v2].select {|vol| vol[:selected] == true}.first
        update_volume_bootable_status(bootable_vol[:uuid])
      end
      i = clone_options[:block_device_mapping_v2].index(bootable_vol)
      clone_options[:block_device_mapping_v2][i][:boot_index] = 0
      clone_options[:block_device_mapping_v2][i][:source_type] = "volume"
      clone_options[:block_device_mapping_v2][i][:destination_type] = "volume"
    end
    source.with_provider_connection(connection_options) do |openstack|
      instance = openstack.servers.create(clone_options)
      add_audit_event(clone_options)
      # public_nets = clone_options[:nics].select{ |net| net['public'] == true }
      # _log.info "PublicIps #{public_nets}"
      # unless public_nets.nil?
      #   public_net = public_nets.first
      #   sleep(5)
      #   os_interfaces = instance.os_interfaces
      #   _log.info "Updating ip #{public_net} #{os_interfaces}"
      #   unless os_interfaces.empty?
      #     interface = os_interfaces.select { |interface| interface.net_id == public_net['net_id']}.first
      #     if interface&.fixed_ips.first
      #       fixed_ip = interface.fixed_ips.first
      #       userid = clone_options[:userid]
      #       allocate_netbox_ip(userid, source.ext_management_system.name, fixed_ip['ip_address'], instance.name)
      #     end
      #   end
      # end

      create_backup_service_vm(instance, clone_options)
      return instance.id
    end
  rescue => e
    error_message = parse_error_message_from_fog_response(e)
    raise MiqException::MiqProvisionError, "An error occurred while provisioning Instance #{clone_options[:name]}: #{error_message}", e.backtrace
  end

  def create_backup_service_vm(instance, clone_options)
    backup_stub = GrpcVm::VmService::Stub.new(Rails.application.config.backup_grpc, :this_channel_is_insecure)
    backup_vm = GrpcVm::VM.new(
      :name => clone_options[:name],
      :ems_ref => instance.id,
      :user_id => clone_options[:block_device_mapping_v2][0][:evm_owner_id]
    )
    backup_stub.create_vm(backup_vm)
  rescue GRPC::BadStatus => e
    _log.error "Error creating backup service VM: #{e.code} - #{e.details}"
  end

  def allocate_netbox_ip(tenant_name, region_name, ip_address, dns_name = nil)
    _log.info "Allocating netbox ip #{ip_address} for tenant #{tenant_name}"
    tenant = NetboxClientRuby.tenancy.tenants.find_by(name: tenant_name)
    if tenant.nil?
      raise Exception, _("Netbox Tenant [#{tenant_name}] not found")
    end

    region = NetboxClientRuby.dcim.regions.find_by(name: region_name)
    if region.nil?
      raise Exception, _("Netbox Region [#{region}] not found")
    end

    NetboxClientRuby::IPAM::IpAddress.new(address: ip_address, tenant: tenant.id, status: 'active', dns_name: dns_name).save
  rescue
    _log.error "Cannot allocate netbox IP [#{ip_address}]"
    # raise Exception, _("Cannot allocate netbox IP [#{ip_address}]")
  end

  def find_available_site(sites)
    selected_site = nil
    selected_prefix = nil
    selected_ips = []
    max_available_ips = 0

    sites.each do |site|
      unless site.tags&.include? "Production"
        next
      end

      ip_prefixes = NetboxClientRuby.ipam.prefixes.filter(site_id: site.id)
      if ip_prefixes.empty?
        next
      end

      prefix, available_ip, allocated_ips = find_ip_prefix(ip_prefixes)
      if available_ip > max_available_ips
        max_available_ips = available_ip
        selected_prefix = prefix
        selected_site = site
        selected_ips = allocated_ips
      end
    end
    [selected_site, selected_prefix, selected_ips]
  end

  def find_ip_prefix(ip_prefixes)
    max_available_ips = 0
    selected_prefix = nil
    allocated_ip = nil
    ip_prefixes.each do |prefix|
      available_ips = NetboxClientRuby.ipam.ips_available(prefix.id).raw_data!
      if available_ips.empty?
        next
      end
      total = available_ips.length
      if total > max_available_ips
        max_available_ips = available_ips.length
        selected_prefix = prefix
        allocated_ip = available_ips[0]
      end
    end
    [selected_prefix, max_available_ips, allocated_ip]
  end
end
