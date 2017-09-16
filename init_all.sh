#!/bin/bash
yum install -y wget 
wget -O /etc/yum.repos.d/epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
sed -i "/mirrors.aliyuncs.com/d" /etc/yum.repos.d/epel.repo /etc/yum.repos.d/CentOS-Base.repo
yum install -y openstack-utils.noarch centos-release-openstack-ocata
yum install python-openstackclient openstack-selinux -y
if [ `egrep -c '(vmx|svm)' /proc/cpuinfo` -eq 0 ];then
	echo "服务器不支持虚拟化，请开启虚拟化功能！"
	exit 1
fi
