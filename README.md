一键部署openstack-ocata
=======================
# 一、说明  
1、一键部署单控制节点，多计算、块节点。  
2、支持中断，多次执行  
3、后续功能有待添加...  

# 二、使用环境  
1、CentOS 7  
#本人的测试环境为7.2版本  

# 三、部署  
1、配置文件  
-------
password：       各项服务密码配置  
openstack.conf： compute、cinder节点IP设置  
hsots：          hosts文件，必须配置各节点能使用主机名互通！  
2、安装  
-------
git clone https://github.com/2432556863/openstack-install.git && cd openstack-install  
#修改配置文件、执行安装脚本  
bash install.sh  
