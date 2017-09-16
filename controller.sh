#!/bin/bash
IP=`ip a|awk -F'[ /]+' '/inet /&&!/127.0.0.1/{print $3}'|head -1`
net_dev=`ip a|awk -F"[ :]+" '!/lo/&&/^[0-9]/{print $2}'|head -1`
ntp_net="`hostname -I|egrep -o '^[^.]+'`/8"
###读取密码配置
. password
#自动发现间隔时间
time=60

#配置ntp服务器
ntp_install(){
	yum install -y chrony
	sed -i '3c server ntp3.aliyun.com iburst' /etc/chrony.conf
	sed -i "22c allow $ntp_net" /etc/chrony.conf
	systemctl restart chronyd.service
	systemctl enable chronyd.service
}
####安装数据库
db_insall(){
	yum install -y mariadb mariadb-server python2-PyMySQL
	cat >/etc/my.cnf.d/openstack.cnf <<-EOF
	[mysqld]
	bind-address = $IP
	
	default-storage-engine = innodb
	innodb_file_per_table = on
	max_connections = 4096
	collation-server = utf8_general_ci
	character-set-server = utf8
	EOF
	systemctl enable mariadb.service
	systemctl restart mariadb.service
	mysql -e "drop database test;drop user root@'::1';drop user ''@'controller';drop user ''@'localhost';" &>/dev/null
	mysqladmin password $MYSQL_PASS
}

#安装rabbitmq消息队列
rabbitmq_install(){
	yum install rabbitmq-server -y
	systemctl enable rabbitmq-server.service
	systemctl restart rabbitmq-server.service
	rabbitmqctl add_user openstack $RABBIT_PASS &>/dev/null
	rabbitmqctl set_permissions openstack ".*" ".*" ".*"
}

#安装mamcache
mamcahe_install(){
	yum install memcached python-memcached -y
	sed -i '$c OPTIONS="-l 127.0.0.1,::1,controller"' /etc/sysconfig/memcached
	systemctl enable memcached.service
	systemctl restart memcached.service
}

#身份服务keystone
Identity_service(){
	#配置keystone服务数据库
	mysql -uroot -p$MYSQL_PASS -e "CREATE DATABASE keystone;GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '"$KEYSTONE_DBPASS"'; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '"$KEYSTONE_DBPASS"';"
	#部署keystone、http服务
	yum install openstack-keystone httpd mod_wsgi -y
	[ -e "/etc/keystone/keystone.conf.bak" ]||cp /etc/keystone/keystone.conf{,.bak}	
	grep -Ev '^$|#' /etc/keystone/keystone.conf.bak >/etc/keystone/keystone.conf
	openstack-config --set /etc/keystone/keystone.conf database connection  mysql+pymysql://keystone:$KEYSTONE_DBPASS@controller/keystone
	openstack-config --set /etc/keystone/keystone.conf token provider fernet
	su -s /bin/sh -c "keystone-manage db_sync" keystone
	keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
	keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
	keystone-manage bootstrap --bootstrap-password $ADMIN_PASS --bootstrap-admin-url http://controller:35357/v3/ --bootstrap-internal-url http://controller:5000/v3/ --bootstrap-public-url http://controller:5000/v3/ --bootstrap-region-id RegionOne
	sed -ri '/^#?ServerName/c ServerName controller' /etc/httpd/conf/httpd.conf
	[ -L "/etc/httpd/conf.d/wsgi-keystone.conf" ] || ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/ 
	systemctl enable httpd.service
	systemctl restart httpd.service
	export OS_USERNAME=admin
	export OS_PASSWORD=$ADMIN_PASS
	export OS_PROJECT_NAME=admin
	export OS_USER_DOMAIN_NAME=Default
	export OS_PROJECT_DOMAIN_NAME=Default
	export OS_AUTH_URL=http://controller:35357/v3
	export OS_IDENTITY_API_VERSION=3
	#创建域，项目，用户和角色
	openstack project create --domain default --description "Service Project" service
	openstack project create --domain default --description "Demo Project" demo
	openstack user create --domain default --password $DEMO_PASS demo
	openstack role create user
	openstack role add --project demo --user demo user
	cat > admin-openrc <<-EOF
	export OS_PROJECT_DOMAIN_NAME=Default
	export OS_USER_DOMAIN_NAME=Default
	export OS_PROJECT_NAME=admin
	export OS_USERNAME=admin
	export OS_PASSWORD=$ADMIN_PASS
	export OS_AUTH_URL=http://controller:35357/v3
	export OS_IDENTITY_API_VERSION=3
	export OS_IMAGE_API_VERSION=2
	EOF
	cat > demo-openrc <<-EOF
	export OS_PROJECT_DOMAIN_NAME=Default
	export OS_USER_DOMAIN_NAME=Default
	export OS_PROJECT_NAME=demo
	export OS_USERNAME=demo
	export OS_PASSWORD=$DEMO_PASS
	export OS_AUTH_URL=http://controller:5000/v3
	export OS_IDENTITY_API_VERSION=3
	export OS_IMAGE_API_VERSION=2	
	EOF
}

#镜像服务
Image_service(){
	mysql -uroot -p$MYSQL_PASS -e "CREATE DATABASE glance;GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '"$GLANCE_DBPASS"';GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '"$GLANCE_DBPASS"';"
	. admin-openrc
	openstack user create --domain default --password $GLANCE_PASS glance
	openstack role add --project service --user glance admin
	openstack service list |grep -q "image" || openstack service create --name glance --description "OpenStack Image" image
	if ! openstack endpoint list|grep -q 'http://controller:9292';then
		openstack endpoint create --region RegionOne image public http://controller:9292
		openstack endpoint create --region RegionOne image internal http://controller:9292
		openstack endpoint create --region RegionOne image admin http://controller:9292
	fi
	yum install openstack-glance -y
	[ -e "/etc/glance/glance-api.conf.bak" ]||cp /etc/glance/glance-api.conf{,.bak}
	grep -Ev '^$|#' /etc/glance/glance-api.conf.bak >/etc/glance/glance-api.conf
	openstack-config --set /etc/glance/glance-api.conf database connection mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_uri  http://controller:5000
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_url  http://controller:35357
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers  controller:11211
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_type  password
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name  default
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name  default
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_name  service
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken username  glance
	openstack-config --set /etc/glance/glance-api.conf keystone_authtoken password  $GLANCE_PASS
	openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone
	openstack-config --set /etc/glance/glance-api.conf glance_store stores  file,http
	openstack-config --set /etc/glance/glance-api.conf glance_store default_store  file
	openstack-config --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir  /var/lib/glance/images/
	[ -e "/etc/glance/glance-registry.conf.bak" ]||cp /etc/glance/glance-registry.conf{,.bak}
	grep -Ev '^$|#' /etc/glance/glance-registry.conf.bak >/etc/glance/glance-registry.conf
	openstack-config --set /etc/glance/glance-registry.conf database connection mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri  http://controller:5000
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_url  http://controller:35357
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken memcached_servers  controller:11211
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_type  password
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_name  default
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_name  default
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_name  service
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken username  glance
	openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken password  $GLANCE_PASS
	openstack-config --set /etc/glance/glance-registry.conf paste_deploy flavor keystone
	su -s /bin/sh -c "glance-manage db_sync" glance
	systemctl enable openstack-glance-api.service openstack-glance-registry.service
	systemctl restart openstack-glance-api.service openstack-glance-registry.service
	echo "验证操作:"
	. admin-openrc
	wget -c http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img
	openstack image create "cirros" --file cirros-0.3.5-x86_64-disk.img --disk-format qcow2 --container-format bare --public
	openstack image list
}
#计算服务
Compute_service(){
	mysql -uroot -p$MYSQL_PASS -e "CREATE DATABASE nova_api;CREATE DATABASE nova;CREATE DATABASE nova_cell0;GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '"$NOVA_DBPASS"';GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '"$NOVA_DBPASS"';GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '"$NOVA_DBPASS"';GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '"$NOVA_DBPASS"';GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '"$NOVA_DBPASS"';GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '"$NOVA_DBPASS"';"
	. admin-openrc
	openstack user create --domain default --password $NOVA_PASS nova
	openstack role add --project service --user nova admin
	openstack service list |grep -q "compute" || openstack service create --name nova --description "OpenStack Compute" compute
	if ! openstack endpoint list|grep -q 'http://controller:8774/v2.1';then
		openstack endpoint create --region RegionOne compute public http://controller:8774/v2.1
		openstack endpoint create --region RegionOne compute internal http://controller:8774/v2.1
		openstack endpoint create --region RegionOne compute admin http://controller:8774/v2.1
	fi
	openstack user create --domain default --password $PLACEMENT_PASS placement
	openstack role add --project service --user placement admin
	openstack service list |grep -q "placement" || openstack service create --name placement --description "Placement API" placement
	if ! openstack endpoint list|grep -q 'http://controller:8778';then
		openstack endpoint create --region RegionOne placement public http://controller:8778
		openstack endpoint create --region RegionOne placement internal http://controller:8778
		openstack endpoint create --region RegionOne placement admin http://controller:8778
	fi
	yum install -y openstack-nova-api openstack-nova-conductor openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler openstack-nova-placement-api
	[ -e "/etc/nova/nova.conf.bak" ]||cp /etc/nova/nova.conf{,.bak}
	grep -Ev '^$|#' /etc/nova/nova.conf.bak >/etc/nova/nova.conf
	openstack-config --set /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata
	openstack-config --set /etc/nova/nova.conf api_database connection mysql+pymysql://nova:$NOVA_DBPASS@controller/nova_api
	openstack-config --set /etc/nova/nova.conf database connection mysql+pymysql://nova:$NOVA_DBPASS@controller/nova
	openstack-config --set /etc/nova/nova.conf DEFAULT transport_url rabbit://openstack:$RABBIT_PASS@controller
	openstack-config --set /etc/nova/nova.conf api auth_strategy keystone
	openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri  http://controller:5000
	openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_url  http://controller:35357
	openstack-config --set /etc/nova/nova.conf keystone_authtoken memcached_servers  controller:11211
	openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_type  password
	openstack-config --set /etc/nova/nova.conf keystone_authtoken project_domain_name  default
	openstack-config --set /etc/nova/nova.conf keystone_authtoken user_domain_name  default
	openstack-config --set /etc/nova/nova.conf keystone_authtoken project_name  service
	openstack-config --set /etc/nova/nova.conf keystone_authtoken username  nova
	openstack-config --set /etc/nova/nova.conf keystone_authtoken password  $NOVA_PASS
	openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $IP
	openstack-config --set /etc/nova/nova.conf DEFAULT use_neutron True
	openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
	openstack-config --set /etc/nova/nova.conf vnc enabled true
	openstack-config --set /etc/nova/nova.conf vnc vncserver_listen '$my_ip'
	openstack-config --set /etc/nova/nova.conf vnc vncserver_proxyclient_address '$my_ip'
	openstack-config --set /etc/nova/nova.conf glance api_servers http://controller:9292
	openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp
	openstack-config --set /etc/nova/nova.conf placement os_region_name RegionOne
	openstack-config --set /etc/nova/nova.conf placement project_domain_name  Default
	openstack-config --set /etc/nova/nova.conf placement project_name  service
	openstack-config --set /etc/nova/nova.conf placement auth_type  password
	openstack-config --set /etc/nova/nova.conf placement user_domain_name  Default
	openstack-config --set /etc/nova/nova.conf placement auth_url  http://controller:35357/v3
	openstack-config --set /etc/nova/nova.conf placement username  placement
	openstack-config --set /etc/nova/nova.conf placement password  $PLACEMENT_PASS
	#设置节点自动发现
	openstack-config --set /etc/nova/nova.conf scheduler discover_hosts_in_cells_interval $time
	grep -q '<Directory /usr/bin>' /etc/httpd/conf.d/00-nova-placement-api.conf ||cat >> /etc/httpd/conf.d/00-nova-placement-api.conf <<-EOF

	<Directory /usr/bin>
	  <IfVersion >= 2.4>
	    Require all granted
	  </IfVersion>
	  <IfVersion < 2.4>
	    Order allow,deny
	    Allow from all
	  </IfVersion>
	</Directory>
	EOF
	systemctl restart httpd
	su -s /bin/sh -c "nova-manage api_db sync" nova
	su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
	su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
	su -s /bin/sh -c "nova-manage db sync" nova
	#检查
	nova-manage cell_v2 list_cells
	systemctl enable openstack-nova-api.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
	systemctl restart openstack-nova-api.service openstack-nova-consoleauth.service openstack-nova-scheduler.service openstack-nova-conductor.service openstack-nova-novncproxy.service
}
#网络服务
Networking_service(){
	mysql -uroot -p$MYSQL_PASS -e " CREATE DATABASE neutron;GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '"$NEUTRON_DBPASS"';GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '"$NEUTRON_DBPASS"';"
	. admin-openrc
	openstack user create --domain default --password $NEUTRON_PASS  neutron
	openstack role add --project service --user neutron admin
	openstack service list |grep -q "network" || openstack service create --name neutron --description "OpenStack Networking" network
	if ! openstack endpoint list|grep -q 'http://controller:9696';then
		openstack endpoint create --region RegionOne network public http://controller:9696
		openstack endpoint create --region RegionOne network internal http://controller:9696
		openstack endpoint create --region RegionOne network admin http://controller:9696
	fi
	##公共网络方式
	yum install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-linuxbridge ebtables
	#配置neutron.conf
	cp /etc/neutron/neutron.conf{,.bak}
	grep '^[a-Z\[]' /etc/neutron/neutron.conf.bak >/etc/neutron/neutron.conf
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT core_plugin  ml2
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT service_plugins
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT auth_strategy  keystone
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT notify_nova_on_port_status_changes  true
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT notify_nova_on_port_data_changes  true
	openstack-config --set /etc/neutron/neutron.conf  DEFAULT transport_url rabbit://openstack:$RABBIT_PASS@controller
	openstack-config --set /etc/neutron/neutron.conf  database connection  mysql+pymysql://neutron:$NEUTRON_DBPASS@controller/neutron
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_uri  http://controller:5000
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_url  http://controller:35357
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken memcached_servers  controller:11211
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken auth_type  password
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken user_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken project_name  service
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken username  neutron
	openstack-config --set /etc/neutron/neutron.conf  keystone_authtoken password  $NEUTRON_PASS
	openstack-config --set /etc/neutron/neutron.conf  nova auth_url  http://controller:35357
	openstack-config --set /etc/neutron/neutron.conf  nova auth_type  password 
	openstack-config --set /etc/neutron/neutron.conf  nova project_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  nova user_domain_name  default
	openstack-config --set /etc/neutron/neutron.conf  nova region_name  RegionOne
	openstack-config --set /etc/neutron/neutron.conf  nova project_name  service
	openstack-config --set /etc/neutron/neutron.conf  nova username  nova
	openstack-config --set /etc/neutron/neutron.conf  nova password  $NOVA_PASS
	openstack-config --set /etc/neutron/neutron.conf  oslo_concurrency lock_path  /var/lib/neutron/tmp
	#配置ml2_conf.ini
	cp /etc/neutron/plugins/ml2/ml2_conf.ini{,.bak}
	grep '^[a-Z\[]' /etc/neutron/plugins/ml2/ml2_conf.ini.bak >/etc/neutron/plugins/ml2/ml2_conf.ini
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 type_drivers  flat,vlan
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 tenant_network_types 
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 mechanism_drivers  linuxbridge
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2 extension_drivers  port_security
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  ml2_type_flat flat_networks  provider
	openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini  securitygroup enable_ipset  True
	#配置linuxbridge_agent.ini
	cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini{,.bak}
	grep '^[a-Z\[]' /etc/neutron/plugins/ml2/linuxbridge_agent.ini.bak >/etc/neutron/plugins/ml2/linuxbridge_agent.ini
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  linux_bridge physical_interface_mappings  provider:$net_dev
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup enable_security_group  true
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  securitygroup firewall_driver  neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
	openstack-config --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini  vxlan enable_vxlan  false
	#配置dhcp_agent.ini
	openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT interface_driver linuxbridge
	openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
	openstack-config --set /etc/neutron/dhcp_agent.ini  DEFAULT enable_isolated_metadata true
	#配置metadata_agent.ini
	openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip  controller
	openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret  $METADATA_SECRET
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
	openstack-config --set   /etc/nova/nova.conf   neutron  service_metadata_proxy    true
	openstack-config --set   /etc/nova/nova.conf   neutron  metadata_proxy_shared_secret    $METADATA_SECRET
	[ -e "/etc/neutron/plugin.ini" ]||ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
	su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
	systemctl restart openstack-nova-api.service
	systemctl enable neutron-server.service neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
	systemctl restart neutron-server.service neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
}
#安装仪表盘
Dashboard(){
	yum install openstack-dashboard -y
	[ -e "/etc/openstack-dashboard/local_settings.bak" ]||cp /etc/openstack-dashboard/local_settings{,.bak}
	sed -i "/ALLOWED_HOSTS/c ALLOWED_HOSTS = ['*', ]" /etc/openstack-dashboard/local_settings
	sed -i '/^OPENSTACK_HOST/c OPENSTACK_HOST = "controller"' /etc/openstack-dashboard/local_settings
	grep -q 'SESSION_ENGINE' /etc/openstack-dashboard/local_settings || sed -i "/^CACHES/i SESSION_ENGINE = 'django.contrib.sessions.backends.cache'" /etc/openstack-dashboard/local_settings
	sed -ri "/^ +'BACKEND':/c \         'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',\n         'LOCATION': 'controller:11211'," /etc/openstack-dashboard/local_settings
	sed -i '/OPENSTACK_KEYSTONE_URL/c OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST' /etc/openstack-dashboard/local_settings
	sed -i '/OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT/c OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True' /etc/openstack-dashboard/local_settings
	sed -i '/OPENSTACK_API_VERSIONS/,+6s/#//g' /etc/openstack-dashboard/local_settings
	sed -i '/data-processing/d' /etc/openstack-dashboard/local_settings
	sed -i '/^#OPENSTACK_KEYSTONE_DEFAULT_DOMAIN/s/#//' /etc/openstack-dashboard/local_settings
	sed -i '/OPENSTACK_KEYSTONE_DEFAULT_ROLE/c OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"' /etc/openstack-dashboard/local_settings
	sed -i '/TIME_ZON/c TIME_ZONE = "Asia/Shanghai"' /etc/openstack-dashboard/local_settings
	sed -i '/OPENSTACK_NEUTRON_NETWOR/,+20s/True/False/g' /etc/openstack-dashboard/local_settings
	systemctl restart httpd.service memcached.service
}
cinder_install(){
	mysql -uroot -p$MYSQL_PASS -e "CREATE DATABASE cinder;GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$CINDER_DBPASS'; GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$CINDER_DBPASS';"
	. admin-openrc
	openstack user create --domain default --password $CINDER_PASS cinder
	openstack role add --project service --user cinder admin
	openstack service list|grep -q 'volumev2' || openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
	openstack service list|grep -q 'volumev3' || openstack service create --name cinderv2
--description "OpenStack Block Storage" volumev3
	if ! openstack endpoint list|grep -q 'http://controller:8776/v2/%\(project_id\)s';then
		openstack endpoint create --region RegionOne volumev2 public http://controller:8776/v2/%\(project_id\)s
		openstack endpoint create --region RegionOne volumev2 internal http://controller:8776/v2/%\(project_id\)s
		openstack endpoint create --region RegionOne volumev2 admin http://controller:8776/v2/%\(project_id\)s
		openstack endpoint create --region RegionOne volumev3 public http://controller:8776/v3/%\(project_id\)s
		openstack endpoint create --region RegionOne volumev3 internal http://controller:8776/v3/%\(project_id\)s
		openstack endpoint create --region RegionOne volumev3 admin http://controller:8776/v3/%\(project_id\)s
	fi
	yum install openstack-cinder -y
	[ -e "/etc/cinder/cinder.conf.bak" ] || cp /etc/cinder/cinder.conf{,.bak}
	grep '^[a-Z\[]' /etc/cinder/cinder.conf.bak > /etc/cinder/cinder.conf
	openstack-config --set  /etc/cinder/cinder.conf  database connection  mysql+pymysql://cinder:$CINDER_DBPASS@controller/cinder
	openstack-config --set  /etc/cinder/cinder.conf  DEFAULT transport_url  rabbit://openstack:$RABBIT_PASS@controller
	openstack-config --set  /etc/cinder/cinder.conf  DEFAULT auth_strategy   keystone
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken auth_uri   http://controller:5000
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken auth_url   http://controller:35357
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken memcached_servers   controller:11211
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken auth_type   password
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken project_domain_name   default
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken user_domain_name   default
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken project_name   service
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken username   cinder
	openstack-config --set  /etc/cinder/cinder.conf  keystone_authtoken password   $CINDER_PASS
	openstack-config --set  /etc/cinder/cinder.conf  DEFAULT my_ip $IP
	openstack-config --set  /etc/cinder/cinder.conf  oslo_concurrency lock_path   /var/lib/cinder/tmp
	su -s /bin/sh -c "cinder-manage db sync" cinder
	openstack-config --set /etc/nova/nova.conf cinder os_region_name RegionOne
	systemctl restart openstack-nova-api.service
	systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
	systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service
}

ntp_install
db_insall
rabbitmq_install
mamcahe_install
Identity_service
Image_service
Compute_service
Networking_service
Dashboard
cinder_install
