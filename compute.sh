#!/bin/bash
IP=`ip a|awk -F'[ /]+' '/inet /&&!/127.0.0.1/{print $3}'|head -1`
net_dev=`ip a|awk -F"[ :]+" '!/lo/&&/^[0-9]/{print $2}'|head -1`
. /tmp/password

ntp_insatll(){
        #配置时间同步
        yum install -y chrony
        sed -i '3c server controller iburst' /etc/chrony.conf
        systemctl restart chronyd.service
        systemctl enable chronyd.service
        ####
}
#计算服务
Compute_service(){
	yum install -y openstack-nova-compute
	[ -e "/etc/nova/nova.conf.bak" ]||cp /etc/nova/nova.conf{,.bak}
	grep -Ev '^$|#' /etc/nova/nova.conf.bak >/etc/nova/nova.conf
	openstack-config --set /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata
	openstack-config --set /etc/nova/nova.conf DEFAULT transport_url rabbit://openstack:$RABBIT_PASS@controller
	openstack-config --set /etc/nova/nova.conf api auth_strategy keystone
	openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri http://controller:5000
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  auth_url  http://controller:35357
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  memcached_servers  controller:11211
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  auth_type  password
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  project_domain_name  default
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  user_domain_name  default
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  project_name  service
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  username  nova
	openstack-config --set /etc/nova/nova.conf keystone_authtoken  password  $NOVA_PASS
	openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $IP
        openstack-config --set /etc/nova/nova.conf DEFAULT use_neutron True
        openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
        openstack-config --set /etc/nova/nova.conf vnc enabled True
        openstack-config --set /etc/nova/nova.conf vnc vncserver_listen 0.0.0.0
        openstack-config --set /etc/nova/nova.conf vnc vncserver_proxyclient_address '$my_ip'
	openstack-config --set /etc/nova/nova.conf vnc novncproxy_base_url http://controller:6080/vnc_auto.html
	openstack-config --set /etc/nova/nova.conf glance api_servers http://controller:9292
	openstack-config --set /etc/nova/nova.conf oslo_concurrenc lock_path /var/lib/nova/tmp
	openstack-config --set /etc/nova/nova.conf placement os_region_name RegionOne
	openstack-config --set /etc/nova/nova.conf placement project_domain_name  Default
	openstack-config --set /etc/nova/nova.conf placement project_name  service
	openstack-config --set /etc/nova/nova.conf placement auth_type  password
	openstack-config --set /etc/nova/nova.conf placement user_domain_name  Default
	openstack-config --set /etc/nova/nova.conf placement auth_url  http://controller:35357/v3
	openstack-config --set /etc/nova/nova.conf placement username  placement
	openstack-config --set /etc/nova/nova.conf placement password  $PLACEMENT_PASS
	systemctl enable libvirtd.service openstack-nova-compute.service
	systemctl restart libvirtd.service openstack-nova-compute.service
}
#网络服务
Networking_service(){
	yum install -y openstack-neutron-linuxbridge ebtables ipset
	#配置neutron.conf
	[ -e "/etc/neutron/neutron.conf.bak" ]||cp /etc/neutron/neutron.conf{,.bak}
	grep -Ev '^$|#' /etc/neutron/neutron.conf.bak >/etc/neutron/neutron.conf
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT transport_url rabbit://openstack:$RABBIT_PASS@controller
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT auth_strategy  keystone
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_uri  http://controller:5000
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_url  http://controller:35357
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken memcached_servers  controller:11211
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_type  password
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken user_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_name  service
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken username  neutron
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken password  $NEUTRON_PASS
	openstack-config --set /etc/neutron/neutron.conf  oslo_concurrency lock_path  /var/lib/neutron/tmp
	#配置linuxbridge_agent.ini
	cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini{,.bak}
	grep -Ev '^$|#' /etc/neutron/plugins/ml2/linuxbridge_agent.ini.bak >/etc/neutron/plugins/ml2/linuxbridge_agent.ini
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  linux_bridge physical_interface_mappings  provider:$net_dev
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup enable_security_group  true
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup firewall_driver  neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  vxlan enable_vxlan  false
	#再次修改nova.conf
	openstack-config --set   /etc/nova/nova.conf   neutron  url    http://controller:9696
	openstack-config --set   /etc/nova/nova.conf   neutron  auth_url    http://controller:35357
	openstack-config --set   /etc/nova/nova.conf   neutron  auth_type    password
	openstack-config --set   /etc/nova/nova.conf   neutron  project_domain_name    default
	openstack-config --set   /etc/nova/nova.conf   neutron  user_domain_name    default
	openstack-config --set   /etc/nova/nova.conf   neutron  region_name    RegionOne
	openstack-config --set   /etc/nova/nova.conf   neutron  project_name    service
	openstack-config --set   /etc/nova/nova.conf   neutron  username    neutron
	openstack-config --set   /etc/nova/nova.conf   neutron  password    $NEUTRON_PASS
	systemctl restart openstack-nova-compute.service
	systemctl enable neutron-linuxbridge-agent.service
	systemctl restart neutron-linuxbridge-agent.service
}
ntp_insatll
Compute_service
Networking_service
