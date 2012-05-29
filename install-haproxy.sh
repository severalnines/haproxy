# All files in this package is subject to the GPL v2 license
# More information is in the COPYING file in the top directory of this package.
# Copyright (C) 2011 Severalnines

# Also see CREDITS, many thanks to Timothy Der (randomorzero.wordpress.com)
# for the work on the makecfg, mysqlckk, and haproxy.cfg.tmpl

#!/bin/bash
source ../.s9s/config
source ../.s9s/help_func

hostnames=`cat ../.s9s/hostnames | grep -v "#"`
# OR specify hosntames here:
#hostnames=a,b,c
MYSQL_PASSWORD="$cmon_password"
MYSQL_USERNAME="cmon"
MYSQL_BINDIR=""
CLUSTER_ID=1
CMON_DB='cmon'


SUFFIX="1"
####  THE FOLLOWING PARAMS IF YOU WANT
HAPROXY_MYSQL_LISTEN_PORT="33306"
LB_NAME="production"
LB_ADMIN_USER='admin'
LB_ADMIN_PASSWORD='admin'
PREFIX="s9s"
#### END OF CHANGE

LB_HOST="$1"
OS="$2"
CLUSTER="$3"


if [ -z $LB_HOST ]; then
  echo "To install haproxy on host <host>, and OS rhel or debian (pick one), "
  echo "and cluster is galera or mysqlcluster do:"
  echo "./install_haproxy.sh <host> <debian|rhel> <galera|mysqlcluster>"
  echo "Only haproxy 1.4.2 and above is tested"
  exit 
fi

PKG_MGR=""


case $OS in
	rhel)
        PKG_MGR="yum install -y "
        MYSQL_BINDIR="/usr/bin"
	;;
	debian)
        PKG_MGR="apt-get install -y "
        MYSQL_BINDIR="/usr/local/mysql/bin"
	;;
	*)
	echo "OS $OS not supported"
	exit
	;;
esac	

case $CLUSTER in
        galera)
        ;;
        mysqlcluster)
        ;;
        *)
        echo "Cluster $CLUSTER not supported"
        exit
        ;;
esac  
	
echo "WARNING! Don't use haproxy with persistent connections"
echo "Press any key to continue"
read $key


echo "Getting hosts from cmon db"

hostnames2=`$MYSQL_BINDIR/mysql -B -N --host=$cmon_monitor --port=$MYSQL_PORT --user=cmon --password=$cmon_password --database=$CMON_DB -e "select group_concat(h.hostname SEPARATOR ' ') from mysql_server m, hosts h WHERE m.id=h.id and h.cid=m.cid and h.ping_status>0 and connected=1 and m.cid=$CLUSTER_ID"`

if [ -z "$hostnames2" ]; then
   echo "Failed to get hostnames from cmon_db"
   echo "Using $hostnames"
else
   hostnames=$hostnames2
fi

if [ -z "$hostnames" ]; then
   echo "No hostnames found."
   exit
fi

echo "Using hostnames $hostnames"

echo "Use the $OS haproxy template:"
echo "cp haproxy.cfg.tmpl.$OS haproxy.cfg.tmpl"
cp haproxy.cfg.tmpl.$OS haproxy.cfg.tmpl
sed -i "s#ADMIN_PASSWORD#$LB_ADMIN_PASSWORD#g" haproxy.cfg.tmpl
sed -i "s#ADMIN_USER#$LB_ADMIN_USER#g" haproxy.cfg.tmpl

echo "Use the $CLUSTER mysqlchk template:"
echo "cp mysqlchk.sh.$CLUSTER mysqlchk.sh"
cp mysqlchk.sh.$CLUSTER mysqlchk.sh

## makecfg.sh requires a certain format on the input file:
# ${PREFIX}_${HAPROXY_MYSQL_LISTEN_PORT}_${LB_NAME}.backend

# Remove previous backend file and generate a new one
rm ${PREFIX}*.backend
sed -i "s#MYSQL_PASSWORD=.*#MYSQL_PASSWORD=\"$MYSQL_PASSWORD\"#g" mysqlchk.sh
sed -i "s#MYSQL_USERNAME=.*#MYSQL_USERNAME=\"$MYSQL_USERNAME\"#g" mysqlchk.sh
sed -i "s#MYSQL_BIN=.*#MYSQL_BIN=\"$MYSQL_BINDIR/mysql\"#g" mysqlchk.sh

echo "*************************************************************"
echo "* installing xinetd, mysqlchk.sh, and creating backend file *"
echo "*************************************************************"
for h in $hostnames 
do
  if [ "$h" = "$LB_HOST" ]; then
       echo "ERROR: Trying to install HaProxy on a database host"
       exit
  fi 
  remote_cmd2 $h  "sed  -i  '/mysqlchk        9200\/tcp/d' /etc/services"
  remote_cmd $h "echo \"mysqlchk        9200/tcp\" | sudo tee --append /etc/services"
  remote_copy mysqlchk.sh $h /tmp 
  remote_cmd $h "mv /tmp/mysqlchk.sh /usr/local/bin"
  remote_cmd $h "chmod 777 /usr/local/bin/mysqlchk.sh"
  remote_cmd $h "$PKG_MGR xinetd"
  remote_copy xinetd_mysqlchk $h /tmp 
  remote_cmd $h "mv /tmp/xinetd_mysqlchk /etc/xinetd.d/mysqlchk"
  remote_cmd $h "/etc/init.d/xinetd restart"
  if [ $OS = "rhel" ]; then
      remote_cmd $h "/sbin/chkconfig --add xinetd"
  else
      remote_cmd $h "/usr/sbin/update-rc.d xinetd defaults"
  fi
  echo $h >> ${PREFIX}_${HAPROXY_MYSQL_LISTEN_PORT}_${LB_NAME}.backend
  echo "Configuration of $h completed "
done
echo ""
echo "*************************************************************"
echo "* writing $PWD/${PREFIX}_${LB_NAME}_haproxy.cfg               *"
echo "*************************************************************"
./makecfg.sh $PREFIX $SUFFIX  > ${PREFIX}_${LB_NAME}_haproxy.cfg
echo ""
echo "*************************************************************"
echo "* Installing haproxy on $LB_HOST                            *"
echo "*************************************************************"

if [ $OS = "rhel" ]; then
   remote_cmd $LB_HOST "$EPEL"
fi
remote_cmd $LB_HOST "$PKG_MGR haproxy"
remote_copy ${PREFIX}_${LB_NAME}_haproxy.cfg $LB_HOST /tmp 
remote_cmd $LB_HOST "rm -f /etc/haproxy/haproxy.cfg"
remote_cmd $LB_HOST "mv /tmp/${PREFIX}_${LB_NAME}_haproxy.cfg /etc/haproxy/haproxy.cfg"
remote_cmd $LB_HOST "/usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -p /var/run/haproxy.pid -st \$(cat /var/run/haproxy.pid)"
echo ""
echo "** Adding init.d/haproxy auto start**"
echo ""

if [ $OS = "rhel" ]; then
      remote_cmd $LB_HOST "/sbin/chkconfig --add haproxy"
else
      remote_cmd $LB_HOST "sed -i 's#ENABLED=.*#ENABLED=1#g' /etc/default/haproxy"
      remote_cmd $LB_HOST "/usr/sbin/update-rc.d haproxy defaults"
fi
echo ""
echo "** Tuning Network **"
echo ""
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.ip_nonlocal_bind.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.ip_nonlocal_bind=1\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.tcp_tw_reuse.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.tcp_tw_reuse=1\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.ip_local_port_range.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.ip_local_port_range = 1024 65023\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.tcp_max_syn_backlog.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.tcp_max_syn_backlog=40000\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.tcp_max_tw_buckets.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.tcp_max_tw_buckets=400000\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.tcp_max_orphans.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.tcp_max_orphans=60000\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.ipv4.tcp_synack_retries.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.ipv4.tcp_synack_retries=3\" | sudo tee --append /etc/sysctl.conf"
remote_cmd2 $LB_HOST "sed  -i  'net.core.somaxconn.*/d' /etc/sysctl.conf"
remote_cmd $LB_HOST  "echo \"net.core.somaxconn=40000\" | sudo tee --append /etc/sysctl.conf"

$MYSQL_BINDIR/mysql --host=$cmon_monitor --port=$MYSQL_PORT --user=cmon --password=$cmon_password --database=$CMON_DB -e "INSERT INTO haproxy_server(cid, lb_host,lb_name,lb_port,lb_admin,lb_password) VALUES ($cluster_id, '$LB_HOST','$LB_NAME', '$LB_ADMIN_PORT', '$LB_ADMIN_USER', $LB_ADMIN_PASSWORD')"


echo ""
echo "** Reboot is needed of $LB_HOST for network settings to take effect! **"
echo ""

echo ""
echo "**The admin interface is on http://${LB_HOST}:9600 **"
echo "**Login with ${ADMIN_USER}/${ADMIN_PASSWORD}"
echo ""
