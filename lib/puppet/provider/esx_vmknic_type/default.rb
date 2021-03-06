# Copyright (C) 2013 VMware, Inc.

require 'pathname' # WORK_AROUND #14073 and #7788
vmware_module = Puppet::Module.find('vmware_lib', Puppet[:environment].to_s)
require File.join vmware_module.path, 'lib/puppet_x/vmware/util'
module_lib = Pathname.new(__FILE__).parent.parent.parent.parent
require File.join module_lib, 'puppet/provider/vcenter'
require File.join module_lib, 'puppet_x/vmware/mapper'

Puppet::Type.type(:esx_vmknic_type).provide(:esx_vmknic_type, :parent => Puppet::Provider::Vcenter) do
  @doc = "Manages ESXi vmknic types - "\
         "management, vmotion, faultToleranceLogging, or vSphereReplication"

  def nic_type
    # create current type list for this vmknic
    nicname = @resource[:nicname]
    is_now = []
    esxhost.configManager.virtualNicManager.info.netConfig.each do |config|
      if vnic = config.candidateVnic.find{|vnic| vnic.device == nicname}

        # check for bug, known to be present in rbvmomi 1.6
        @check_unableToGetCurrentConfig ||= config.selectedVnic &&
            # correct type is String[] or []; anything else will fail
            (config.selectedVnic.select{|el| not String === el} != [])

        if config.selectedVnic.include? vnic.key
          # If using rbvmomi 1.6, this code won't be executed. If the bug
          # is fixed in a later version, the code should work.

          # The vSphere API returns a list of strings in selectedVnic,
          # and rbvmomi 1.6 attempts to turn it into a list of HostVirtualNic.
          # This fails, but the values in selectedVnic are overwritten and 
          # will never match vnic.key.

          is_now << config.nicType
        end
      end
    end
    # In type, 'newvalues' forces input strings to 
    # Symbols; match that so insync? will be happy.
    @nic_type_is_now = is_now.map{|type| type.to_s.to_sym}.sort
  end

  def nic_type= should
    should = should # .map{|type| type.to_s}
    is_now = @nic_type_is_now # .map{|type| type.to_s}
    deselect = is_now - should
    select   = should - is_now

    if @check_unableToGetCurrentConfig
      # use of 'newvalues' in type creates symbols in array
      all = [:management, :vmotion, :faultToleranceLogging, :vSphereReplication]
      select   = should
      deselect = all - select
    end

    vnm = esxhost.configManager.virtualNicManager
    device = @resource[:nicname]

    select.sort.each do |type|
      begin
        next if type == :vmotion && selected_with_tcp_ip_netstack?(type, device)
        vnm.SelectVnicForNicType(:nicType => type, :device => device)
      rescue RbVmomi::VIM::InvalidArgument => e
        fail e.message
      rescue
        retry_counter ||= 1
        fail $!.message if retry_counter > 5

        Puppet.debug("Failed to update NIC Type %s for %s" % [should, device])
        sleep(60)
        retry_counter += 1

        retry
      end
    end
    deselect.sort.each do |type|
      begin
        vnm.DeselectVnicForNicType(:nicType => type, :device => device)
      rescue RbVmomi::VIM::InvalidArgument => e
        if e.invalidProperty == "device"
          # vsphere returns invalidProperty == device when the device 
          # was requested for deselection, but was not selected; since
          # we can't get the current status sometimes, due to bug in
          # rbvmomi 1.6, we ignore the error
        else
          # invalidProperty == "nic type" for misspelled types, for example
          fail e.message
        end
      end
    end
  end

  private

  def selected_with_tcp_ip_netstack?(type, device)
    vnm = esxhost.configManager.virtualNicManager
    nconfig = vnm.info.netConfig

    target_netconfigs = nconfig.select {|nc| nc.nicType == type.to_s}
    fail "More than one vnic is selected for the target nicType" if target_netconfigs.count > 1

    target_netconfig = target_netconfigs.first
    target_devices = target_netconfig.candidateVnic.select {|vnic| vnic.device == device}
    fail "More than one vnic is found for one device" if target_devices.count > 1

    target_device = target_devices.first
    result = target_device.spec.netStackInstanceKey == type.to_s

    result
  end

  def esxhost
    host(@resource[:esxi_host])
  end
end
