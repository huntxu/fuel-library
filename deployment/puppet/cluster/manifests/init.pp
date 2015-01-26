# == Class: cluster
#
# Module for configuring cluster resources.
#
class cluster (
    $internal_address  = '127.0.0.1',
    $unicast_addresses = undef,
) {

    #todo: move half of openstack::corosync
    #to this module, another half -- to Neutron

    case $::osfamily {
      'RedHat': {
        $pcs_package = 'pcs'
      }
      'Debian': {
        $pcs_package = 'python-pcs'
      }
       default: {
        fail("Unsupported osfamily: ${::osfamily} operatingsystem: ${::operatingsystem},\
 module ${module_name} only support osfamily RedHat and Debian")
      }
    }

    if defined(Stage['corosync_setup']) {
      class { 'openstack::corosync':
        bind_address      => $internal_address,
        unicast_addresses => $unicast_addresses,
        stage             => 'corosync_setup',
        corosync_version  => '2',
        packages          => ['corosync', 'pacemaker', 'crmsh', $pcs_package],
      }
    } else {
      class { 'openstack::corosync':
        bind_address      => $internal_address,
        unicast_addresses => $unicast_addresses,
        corosync_version  => '2',
        packages          => ['corosync', 'pacemaker', 'crmsh', $pcs_package],
      }
    }

    # NOTE(bogdando) dirty hack to make corosync with pacemaker service ver:1 working #1417972
    exec { 'stop-pacemaker':
      command     => 'service pacemaker stop || true',
      path        => '/bin:/usr/bin/:/sbin:/usr/sbin',
    }
    File<| title == '/etc/corosync/corosync.conf' |> ~> Exec['stop-pacemaker'] ~> Service['corosync']

    file { 'ocf-mirantis-path':
      ensure  => directory,
      path    =>'/usr/lib/ocf/resource.d/mirantis',
      recurse => true,
      owner   => 'root',
      group   => 'root',
    }
    Package['corosync'] -> File['ocf-mirantis-path']
    Package<| title == 'pacemaker' |> -> File['ocf-mirantis-path']

    file { 'ns-ipaddr2-ocf':
      path   =>'/usr/lib/ocf/resource.d/mirantis/ns_IPaddr2',
      mode   => '0755',
      owner  => root,
      group  => root,
      source => 'puppet:///modules/cluster/ns_IPaddr2',
    }

    Package['pacemaker'] -> File['ns-ipaddr2-ocf']
    File<| title == 'ocf-mirantis-path' |> -> File['ns-ipaddr2-ocf']

}
#
###
