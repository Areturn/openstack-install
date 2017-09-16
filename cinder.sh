#!/bin/bash
IP=`ip a|awk -F'[ /]+' '/inet /&&!/127.0.0.1/{print $3}'|head -1`
disk=($(ls /dev/sd? | sed -r "s#$(blkid|grep -oP "$(ls /dev/sd?|xargs|tr ' ' '|')"|xargs|tr ' ' '|')##g"|grep '.'))
vg_name="cinder-`hostname`"
. /tmp/password

yum install -y lvm2
systemctl enable lvm2-lvmetad.service
systemctl start lvm2-lvmetad.service

lvm_list="$(ls /dev/sd?|sort|awk '{printf "\"a/"$0"/\", "}END{print x}')"

if grep -qP '\tfilter = \[' /etc/lvm/lvm.conf;then
	sed -ri '/\tfilter = \[/c \\tfilter = [ '"$lvm_list"'"r/.*/"]' /etc/lvm/lvm.conf
else
	sed -ri '/devices \{/s#.*#&\n\tfilter = [ '"$lvm_list"'"r/.*/"]#' /etc/lvm/lvm.conf
fi

[ -n "$disk" ] && for i in `echo ${disk[*]}`;do
        pvcreate $i
	if pvs|grep -q "$vg_name" ;then
		vgreduce $vg_name $i
	else
        	vgcreate $vg_name $i
	fi
done

yum install openstack-cinder targetcli python-keystone -y
[ -e "/etc/cinder/cinder.conf.bak" ]||cp /etc/cinder/cinder.conf{,.bak}
grep '^[a-Z\[]' /etc/cinder/cinder.conf.bak > /etc/cinder/cinder.conf
openstack-config --set  /etc/cinder/cinder.conf  database connection  mysql+pymysql://cinder:$CINDER_DBPASS@controller/cinder
openstack-config --set  /etc/cinder/cinder.conf  DEFAULT transport_url  rabbit://openstack:RABBIT_PASS@controller
openstack-config --set  /etc/cinder/cinder.conf  DEFAULT auth_strategy   keystone
openstack-config --set  /etc/cinder/cinder.conf  DEFAULT glance_api_servers http://controller:9292
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
openstack-config --set  /etc/cinder/cinder.conf  DEFAULT enabled_backends  lvm
openstack-config --set /etc/cinder/cinder.conf  lvm
openstack-config --set /etc/cinder/cinder.conf  lvm volume_driver   cinder.volume.drivers.lvm.LVMVolumeDriver
openstack-config --set /etc/cinder/cinder.conf  lvm volume_group   $vg_name
openstack-config --set /etc/cinder/cinder.conf  lvm iscsi_protocol   iscsi
openstack-config --set /etc/cinder/cinder.conf  lvm iscsi_helper   lioadm
openstack-config --set  /etc/cinder/cinder.conf  oslo_concurrency lock_path   /var/lib/cinder/tmp
systemctl enable openstack-cinder-volume.service target.service
systemctl restart openstack-cinder-volume.service target.service
