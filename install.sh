#!/bin/bash
. password
[ $UID -ne 0 ]&&echo "请使用root用户运行脚本!"&&exit 2
init_node(){
	bash init_all.sh
	rpm -q expect sshpass &>/dev/null || yum install expect sshpass -y
	#配置所有节点的hosts文件、主机名、环境
	hostnamectl set-hostname controller
	BAK=$IFS
	IFS=$'\n'
	for i in `awk '$2!~/controller/||NR>2' hosts` ;do
		ip=`echo $i|awk '{print $1}'`
		name=`echo $i|awk '{print $2}'`
		sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no hosts $ip:/etc/hosts &>/dev/null
		sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no $ip "hostnamectl set-hostname $name"
		sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no init_all.sh $ip:/tmp/init_all.sh
		sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no $ip "bash /tmp/init_all.sh"
		[ $? -eq 0 ]||exit 1
	done
	IFS=$BAK
}

controller_install(){
	bash controller.sh
}

compute_install(){
	compute_host=`awk '/\[compute\]/{a=1;next}/\[/{a=0}a&&!/^$|[ \t]+/{print $0}' openstack.conf`
	[ -n "$compute_host" ] && for i in $compute_host;do
		sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no password $i:/tmp/password
		sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no compute.sh $i:/tmp/compute.sh
		sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no $i "bash /tmp/compute.sh"
	done
}

cinder_install(){
	cinder_host=`awk '/\[cinder\]/{a=1;next}/\[/{a=0}a&&!/^$|[ \t]+/{print $0}' openstack.conf`
	[ -n "$cinder_host" ] && for i in $cinder_host;do
                sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no password $i:/tmp/password
                sshpass -p $SSH_PASS scp -o StrictHostKeyChecking=no cinder.sh $i:/tmp/cinder.sh
                sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no $i "bash /tmp/cinder.sh"
        done
}
#启动测试实例的准备
Test_instance(){
	#创建虚拟网络
	. admin-openrc
	openstack network create  --share --external \
  --provider-physical-network provider \
  --provider-network-type flat provider
	openstack subnet create --network provider \
  --allocation-pool start=${RANGE/,*/},end=${RANGE/*,/} \
  --dns-nameserver $DNS --gateway $GW \
  --subnet-range $SUBNET_RANGE provider	
	#创建m1.nano 64M内存模板
	openstack flavor create --id 0 --vcpus 1 --ram 64 --disk 1 m1.nano
	[ -e "/root/.ssh/id_rsa" ]||ssh-keygen -q -N "" -f /root/.ssh/id_rsa
	openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey
	openstack keypair list
	#添加安全组规则
	openstack security group rule create --proto icmp default
	#开放22端口
	openstack security group rule create --proto tcp --dst-port 22 default
	#打开网页启动实例测试
}
menu(){
	cat<<-EOF
	1、请确认服务器虚拟化功能已开启！！！
	2、脚本将会在本机上部署controller控制节点,确保本机主机名为controller！
	3、将你准备好的hosts文件放在本脚本目录下！
	4、在openstack.conf文件中配置compute、cinder节点的ip！
	5、password文件中配置各服务密码。
	6、暂时只支持一次性部署（支持中断多次执行），后期将支持添加compute、cinder节点功能！
	EOF
	read -p "确认安装:[y]" value
	if [ "$value" == "y" -o "$value" == "yes" ];then
		echo "开始安装："
	else
		echo "取消安装！"
		exit 1
	fi
}
menu
init_node
controller_install
compute_install
cinder_install
Test_instance
