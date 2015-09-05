# Native linux bonding implementation
# INspired by: https://www.kernel.org/doc/Documentation/networking/bonding.txt
#

require File.join(File.dirname(__FILE__), '..','..','..','puppet/provider/lnx_base')

Puppet::Type.type(:l2_bond).provide(:lnx, :parent => Puppet::Provider::Lnx_base) do
  defaultfor :osfamily    => :linux
  commands   :iproute     => 'ip',
             :ethtool_cmd => 'ethtool',
             :brctl       => 'brctl'


  def self.prefetch(resources)
    interfaces = instances
    resources.keys.each do |name|
      if provider = interfaces.find{ |ii| ii.name == name }
        resources[name].provider = provider
      end
    end
  end

  def self.instances
    bonds ||= self.get_lnx_bonds()
    debug("bonds found: #{bonds.keys}")
    rv = []
    bonds.each_pair do |bond_name, bond_props|
        props = {
          :ensure          => :present,
          :name            => bond_name,
          :vendor_specific => {}
        }
        props.merge! bond_props
        # # get bridge if port included to it
        # if ! port_bridges_hash[if_name].nil?
        #   props[:bridge] = port_bridges_hash[if_name][:bridge]
        # end
        # # calculate port_type field
        # if !bridges[if_name].nil?
        #   case bridges[if_name][:br_type]
        #   when :ovs
        #     props[:port_type] = 'ovs:br:unremovable'
        #   when :lnx
        #     props[:port_type] = 'lnx:br:unremovable'
        #   else
        #     # pass
        #   end
        # end
        debug("PREFETCHED properties for '#{bond_name}': #{props}")
        rv << new(props)
    end
    rv
  end

  def create
    debug("CREATE resource: #{@resource}")
    @old_property_hash = {}
    @property_flush = {}.merge! @resource
    open('/sys/class/net/bonding_masters', 'a') do |f|
      f << "+#{@resource[:name]}"
    end
  end

  def destroy
    debug("DESTROY resource: #{@resource}")
    open('/sys/class/net/bonding_masters', 'a') do |f|
      f << "-#{@resource[:name]}"
    end
  end

  def flush
    if ! @property_flush.empty?
      debug("FLUSH properties: #{@property_flush}")
      #
      # FLUSH changed properties
      if @property_flush.has_key? :slaves
        runtime_slave_ports = File.open("/sys/class/net/#{@resource[:bond]}/bonding/slaves", "r").read.split(/\s+/)
        if @property_flush[:slaves].nil? or @property_flush[:slaves] == :absent
          debug("Remove all slave ports from bond '#{@resource[:bond]}'")
          rm_slave_list = runtime_slave_ports
        else
          rm_slave_list = runtime_slave_ports - @property_flush[:slaves]
          debug("Remove '#{rm_slave_list.join(',')}' ports from bond '#{@resource[:bond]}'")
          rm_slave_list.each do |slave|
            iproute('link', 'set', 'down', 'dev', slave)  # need by kernel requirements by design. undocumented :(
            File.open("/sys/class/net/#{@resource[:bond]}/bonding/slaves", "a") {|f| f << "-#{slave}"}
          end
          # add interfaces to bond
          (@property_flush[:slaves] - runtime_slave_ports).each do |slave|
            iproute('link', 'set', 'down', 'dev', slave)  # need by kernel requirements by design. undocumented :(
            debug("Add interface '#{slave}' to bond '#{@resource[:bond]}'")
            File.open("/sys/class/net/#{@resource[:bond]}/bonding/slaves", "a") {|f| f << "+#{slave}"}
            iproute('link', 'set', 'up', 'dev', slave)
          end
        end
      end
      if @property_flush.has_key? :bond_properties
        # change bond_properties
        bond_prop_dir = "/sys/class/net/#{@resource[:bond]}"
        need_reassemble = [:mode, :lacp_rate]
        #todo(sv): inplement re-assembling only if it need
        #todo(sv): re-set only delta between reality and requested
        runtime_bond_state  = !self.class.get_iface_state(@resource[:bond]).nil?
        runtime_slave_ports = self.class.get_sys_class("#{bond_prop_dir}/bonding/slaves", true)
        runtime_slave_ports.each do |eth|
          # for most bond options we should disassemble bond before re-configuration. In the kernel module documentation
          # says, that bond interface should be downed, but it's not enouth.
          self.class.set_sys_class("#{bond_prop_dir}/bonding/slaves", "-#{eth}")
        end
        iproute('link', 'set', 'down', 'dev', @resource[:bond])
        # setup primary bond_properties
        primary_bond_properties = [:mode, :xmit_hash_policy]
        curr_mode = self.class.get_sys_class("#{bond_prop_dir}/bonding/mode")
        if curr_mode != @property_flush[:bond_properties][:mode]
          debug("Setting mode '#{@property_flush[:bond_properties][:mode]}' for bond '#{@resource[:bond]}'")
          self.class.set_sys_class("#{bond_prop_dir}/bonding/mode", @property_flush[:bond_properties][:mode])
          sleep(1)
        end
        curr_xhp = self.class.get_sys_class("#{bond_prop_dir}/bonding/xmit_hash_policy")
        if @property_flush[:bond_properties].has_key?(:xmit_hash_policy) && curr_mode != @property_flush[:bond_properties][:xmit_hash_policy]
          debug("Setting xmit_hash_policy '#{@property_flush[:bond_properties][:xmit_hash_policy]}' for bond '#{@resource[:bond]}'")
          self.class.set_sys_class("#{bond_prop_dir}/bonding/xmit_hash_policy", @property_flush[:bond_properties][:xmit_hash_policy])
          sleep(1)
        end
        # setup another bond_properties
        @property_flush[:bond_properties].reject{|k,v| primary_bond_properties.include? k}.each_pair do |prop, val|
          if self.class.lnx_bond_allowed_properties_list.include? prop.to_sym
            val_should_be = val.to_s
            val_actual = self.class.get_sys_class("#{bond_prop_dir}/bonding/#{prop}")
            if val_actual != val_should_be
              debug("Setting property '#{prop}' to '#{val_should_be}' for bond '#{@resource[:bond]}'")
              self.class.set_sys_class("#{bond_prop_dir}/bonding/#{prop}", val_should_be)
            end
          else
            debug("Unsupported property '#{prop}' for bond '#{@resource[:bond]}'")
          end
        end
        # re-assemble bond after configuration
        iproute('link', 'set', 'up', 'dev', @resource[:bond]) if runtime_bond_state
        runtime_slave_ports.each do |eth|
          self.class.set_sys_class("#{bond_prop_dir}/bonding/slaves", "+#{eth}")
        end
      end
      if @property_flush.has_key? :bridge
        # get actual bridge-list. We should do it here,
        # because bridge may be not existing at prefetch stage.
        @bridges ||= self.class.get_bridge_list()
        debug("Actual-bridge-list: #{@bridges}")
        port_bridges_hash = self.class.get_port_bridges_pairs()
        debug("Actual-port-bridge-mapping: '#{port_bridges_hash}'")       # it should removed from LNX
        #
        # remove interface from old bridge
        runtime_bond_state  = !self.class.get_iface_state(@resource[:bond]).nil?
        iproute('--force', 'link', 'set', 'down', 'dev', @resource[:bond])
        if ! port_bridges_hash[@resource[:bond]].nil?
          br_name = port_bridges_hash[@resource[:bond]][:bridge]
          if br_name != @resource[:bond]
            # do not remove bridge-based interface from his bridge
            case port_bridges_hash[@resource[:bond]][:br_type]
            when :ovs
              ovs_vsctl(['del-port', br_name, @resource[:bond]])
              # todo catch exception
            when :lnx
              brctl('delif', br_name, @resource[:bond])
              # todo catch exception
            else
              #pass
            end
          end
        end
        # add port to the new bridge
        if !@property_flush[:bridge].nil? and @property_flush[:bridge].to_sym != :absent
          case @bridges[@property_flush[:bridge]][:br_type]
          when :ovs
            ovs_vsctl(['add-port', @property_flush[:bridge], @resource[:bond]])
          when :lnx
            brctl('addif', @property_flush[:bridge], @resource[:bond])
          else
            #pass
          end
        end
        iproute('link', 'set', 'up', 'dev', @resource[:bond]) if runtime_bond_state
        debug("Change bridge")
      end
      if @property_flush[:onboot]
        iproute('link', 'set', 'up', 'dev', @resource[:bond])
      end
      if !['', 'absent'].include? @property_flush[:mtu].to_s
        self.class.set_mtu(@resource[:bond], @property_flush[:mtu])
      end
      @property_hash = resource.to_hash
    end
  end

  #-----------------------------------------------------------------
  def slaves
    @property_hash[:slaves] || :absent
  end
  def slaves=(val)
    @property_flush[:slaves] = val
  end

  def bond_properties
    @property_hash[:bond_properties] || :absent
  end
  def bond_properties=(val)
    @property_flush[:bond_properties] = val
  end

  def interface_properties
    @property_hash[:interface_properties] || :absent
  end
  def interface_properties=(val)
    @property_flush[:interface_properties] = val
  end

end
# vim: set ts=2 sw=2 et :
