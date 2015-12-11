PostgreSQL Replication, and load balancing with pgpool2 / repmgr
=================================================================

PostgreSQL流复制 + Pgpool-2实现高可用（HA）

[TOC]

## 介绍：

最近花了不少时间在PostgreSQL上面，虽然进度缓慢不过还是总结一下的好。

简而言之，本文将包含 使用PostgreSQL搭建的主从数据库集群（使用Streaming Replication功能）、使用pgpool-2实现负载均衡、和故障切换。其中PostgreSQL的Replication是使用第三方工具repmgr进行管理的。
- Replication
- Load balancing
- Failover & Online recovery

环境和相关软件版本：
- Ubuntu 14.04.3 LTS, trusty
- postgresql v9.3
- pgpool-II v3.3.4 (tokakiboshi)
- pgpoolAdmin3 v3.4.1 (http://www.pgpool.net/download.php?f=pgpoolAdmin-3.4.1.tar.gz)
- repmgr v0

系统的网络图如下，包含:  
- Node-Primary: the master postgresql node, of the cluster
- Node-Standby: the slave postgresql node, of the cluster
- Balancer-Primary: the pgpool server 01
- Balancer-Secondary: the pgpool server 02

![系统的网络图][img-1-network-diagram]

## Step by step:

Node-Primary installation: the master postgresql database server installation/configuration.

``` shell
#!/usr/bin/env bash
# Bash3 Boilerplate. Copyright (c) 2014, kvz.io

set -o errexit
set -o pipefail
set -o nounset
set -o xtrace

# The script needs to be run as root
if [[ $(id -u) -ne 0 ]] ; then
    echo "This script needs to be run as root";
    exit 0;
fi

######: Start with params
# shell script for pg-node-master
DEFAULT_MASTER_HOST_ADDRESS=192.168.3.11
CURRENT_NODE_ADDRESS=192.168.3.11
CURRENT_NODE_NAME=pg-node-1

######: Install packages
# Add the APT repository of PostgreSQL packages for Debian and Ubuntu
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update

# Install: basic, for auto-typein ssh password
sudo apt-get -y --force-yes install sshpass
# Install PostgreSQL 9.3 (Server, Client)
sudo apt-get -y --force-yes install postgresql-9.3 postgresql-contrib-9.3
sudo apt-get -y --force-yes install postgresql-client-9.3 postgresql-client-common
sudo apt-get -y --force-yes install postgresql-9.3-repmgr
sudo apt-get -y --force-yes install postgresql-9.3-pgpool2


# Checking: if postgresql service has been succefully installed
sudo service postgresql status

######: Set linux user password for postgres
# Change password to 'a' for user postgres
echo -e "a\na\n" | sudo passwd postgres


######: 
# Set up trusted copy between the servers
# 所有的Slave都在clone时把自己的key提交到master，同时把master上的数据复制到slave.local
sudo su - postgres -c sh <<EOF
# Generate a new RSA-keypair, # ssh-copy-id -i ~/.ssh/id_rsa.pub <slave hostname>
ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
chmod 740 .ssh/

# Adding authorized_keys, cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
sshpass -p 'a' ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub 192.168.3.11

# Adding known_hosts, ssh-keyscan -H 192.168.3.11 | sudo tee ~/.ssh/known_hosts
sshpass -p 'a' ssh -o StrictHostKeyChecking=no postgres@192.168.3.11
EOF


# key file change notification
# after other slave updated the (authorized_keys & known_hosts), master need to push these 2 files to all other slave
sudo apt-get install incron
sudo rm /etc/incron.allow
sudo chmod 777 /var/spool/incron/
cat > ~/temp-incron-tab.conf <<EOF
/var/lib/postgresql/.ssh IN_MODIFY,IN_CLOSE_WRITE sh /var/lib/postgresql/icron-job-key-change-notification.conf
EOF
sudo incrontab -u postgres ~/temp-incron-tab.conf
sudo rm ~/temp-incron-tab.conf
sudo service incron restart


######: Update-Conf: postgresql.conf
THE_POSTGRESQL_CONF="/etc/postgresql/9.3/main/postgresql.conf"
sudo -u postgres bash <<EOF
set_conf () {
    local tkey=\$1; local tvalue=\$2; local tfile=\$3
    sed -i.bak -e "s/^#*\\s*\\(\$tkey\\s*=\\s*\\).*\\\$/\\1\$tvalue/" \$tfile
    echo "===> set params completed: \$tkey, \$tvalue, \$tfile"
    return 0
}

set_conf listen_addresses \'*\' $THE_POSTGRESQL_CONF
set_conf wal_level hot_standby $THE_POSTGRESQL_CONF
set_conf wal_keep_segments 5000 $THE_POSTGRESQL_CONF
set_conf max_wal_senders 5 $THE_POSTGRESQL_CONF
set_conf hot_standby on $THE_POSTGRESQL_CONF
set_conf archive_mode on $THE_POSTGRESQL_CONF
set_conf archive_command \'cd .\' $THE_POSTGRESQL_CONF
EOF

######: Updating: pg_hba.conf
sudo -u postgres sh <<EOF
cat >> /etc/postgresql/9.3/main/pg_hba.conf <<EOFcat
# tw: to allow LAN slave nodes access
host    replication     repmgr_usr      192.168.3.0/24          trust
host    all             repmgr_usr      192.168.3.0/24          trust
host    all             pgpool_usr      192.168.3.0/24          trust
# tw: adding more entries
host    all             all             127.0.0.1/32            trust
host    all             all             192.168.3.0/24          md5
host    all             all             0.0.0.0/0               md5
EOFcat
EOF

######: repmgr: Create the directory & conf for repmgr
sudo su - postgres -c "mkdir -p /var/lib/postgresql/repmgr/"
sudo su - postgres -c "cat > /var/lib/postgresql/repmgr/repmgr.conf <<EOF
cluster=my_pgsql_cluster
node=1
node_name=$CURRENT_NODE_NAME

conninfo='host=$CURRENT_NODE_ADDRESS user=repmgr_usr dbname=repmgr_db'
pg_bindir=/usr/lib/postgresql/9.3/bin
master_response_timeout=5

reconnect_attempts=2
reconnect_interval=2

failover=manual
promote_command='/usr/bin/repmgr standby promote -f /var/lib/postgresql/repmgr/repmgr.conf'
follow_command='/usr/bin/repmgr standby follow -f /var/lib/postgresql/repmgr/repmgr.conf'
EOF"

######: 
# chown -R postgres:postgres /var/lib/pgsql/.ssh /var/lib/pgsql/.pgpass /var/lib/pgsql/repmgr
chown -R postgres:postgres /var/lib/postgresql/repmgr

service postgresql --full-restart

# repmgr: Add users / roles
sudo -u postgres psql -c "CREATE ROLE pgpool_usr SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION LOGIN ENCRYPTED PASSWORD 'a';"
sudo -u postgres psql -c "CREATE USER repmgr_usr SUPERUSER LOGIN ENCRYPTED PASSWORD 'a';"
sudo -u postgres psql -c "CREATE DATABASE repmgr_db OWNER repmgr_usr;"
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'a';"

# repmgr: Register the master node with repmgr
sudo su - postgres -c "/usr/bin/repmgr -f /var/lib/postgresql/repmgr/repmgr.conf --verbose master register"
sudo su - postgres -c "service postgresql --full-restart"
```

Node-Standby installation: the slave postgresql database server installation/configuration.

``` shell
#!/bin/sh
# Bash3 Boilerplate. Copyright (c) 2014, kvz.io

set -o errexit
set -o pipefail
set -o nounset
set -o xtrace

# The script needs to be run as root
if [[ $(id -u) -ne 0 ]] ; then
    echo "This script needs to be run as root";
    exit 0;
fi

######: Start with params
# shell script for pg-node-slave
DEFAULT_MASTER_HOST_ADDRESS=192.168.3.11
CURRENT_NODE_ADDRESS=192.168.3.12
CURRENT_NODE_NAME=pg-node-2

######: Install packages
# Add the APT repository of PostgreSQL packages for Debian and Ubuntu
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update

# Install: basic, for auto-typein ssh password
sudo apt-get -y --force-yes install sshpass
# Install PostgreSQL 9.3 (Server, Client)
sudo apt-get -y --force-yes install postgresql-9.3 postgresql-contrib-9.3
sudo apt-get -y --force-yes install postgresql-client-9.3 postgresql-client-common
sudo apt-get -y --force-yes install postgresql-9.3-repmgr
sudo apt-get -y --force-yes install postgresql-9.3-pgpool2


# Checking: if postgresql service has been succefully installed
sudo service postgresql status

######: Set linux user password for postgres
# Change password to 'a' for user postgres
echo -e "a\na\n" | sudo passwd postgres


######: 
# Set up trusted copy between the servers
# One option at this point, to setup public key authentication, would be to repeat the steps as we
# did for root. But I’ll just reuse the generated keys, known_hosts and authorized_keys from root
# and use them for user postgres:
sudo su - postgres -c sh <<EOF
# generate a new RSA-keypair, # ssh-copy-id -i ~/.ssh/id_rsa.pub <slave hostname>
ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""

# remote-adding authorized_keys: add the generated public keys of current slave to master ~/.ssh/authorized_keys
sshpass -p 'a' ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub $DEFAULT_MASTER_HOST_ADDRESS

# remote-adding known_hosts, ssh-keyscan -H 192.168.3.12 | sudo tee ~/.ssh/known_hosts
# sshpass -p 'a' ssh -t postgres@$DEFAULT_MASTER_HOST_ADDRESS "sshpass -p 'a' ssh -o StrictHostKeyChecking=no postgres@$CURRENT_NODE_ADDRESS"
sshpass -p 'a' ssh -o StrictHostKeyChecking=no -t postgres@$DEFAULT_MASTER_HOST_ADDRESS "sshpass -p 'a' ssh-keyscan -H $CURRENT_NODE_ADDRESS | tee -a ~/.ssh/known_hosts"

# Grab public-key-authentication-files from Master (.ssh)
sshpass -p 'a' scp -o StrictHostKeyChecking=no -r $DEFAULT_MASTER_HOST_ADDRESS:~/.ssh/{authorized_keys,known_hosts} ~/.ssh
EOF

# register key-file change notification
# after other slave updated the (authorized_keys & known_hosts), master need to push these 2 files to all other slave
sudo su - postgres -c "
sshpass -p \'a\' ssh -o StrictHostKeyChecking=no -t postgres@$DEFAULT_MASTER_HOST_ADDRESS \"
cat >> /var/lib/postgresql/icron-job-key-change-notification.conf <<\EOFcat
sshpass -p 'a' scp -o StrictHostKeyChecking=no -r /var/lib/postgresql/.ssh/authorized_keys /var/lib/postgresql/.ssh/known_hosts $CURRENT_NODE_ADDRESS:/var/lib/postgresql/.ssh
EOFcat
\"
"

# Common functions:
set_conf () {
    local tkey=$1; local tvalue=$2; local tfile=$3
    sed -i.bak -e "s/^#*\s*\($tkey\s*=\s*\).*\$/\1$tvalue/" $tfile
    echo "===> set params completed: $tkey, $tvalue, $tfile"
    return 0
}

# =====================================

# Check the connection to primary node
sudo su - postgres -c "psql --username=repmgr_usr --dbname=repmgr_db --host $DEFAULT_MASTER_HOST_ADDRESS -w -l"

# Use repmgr standby clone to clone a standby from the master: (Replicate the DB from the master mode)
sudo -u postgres sh <<EOF
## 1. stop service & remove pre-database files
service postgresql stop
rm -rf /var/lib/postgresql/9.3/main/*

## 2. standby clone from the master
/usr/bin/repmgr -D /var/lib/postgresql/9.3/main -d repmgr_db -p 5432 -U repmgr_usr -R postgres --verbose standby clone $DEFAULT_MASTER_HOST_ADDRESS

## 3. copy master conf(s) to standby conf directory (by default, repmger will sync master confs to local PGDATA directory)
cp -rf /var/lib/postgresql/9.3/main/postgresql.conf \
    /var/lib/postgresql/9.3/main/pg_hba.conf \
    /var/lib/postgresql/9.3/main/pg_ident.conf \
    /etc/postgresql/9.3/main/
rm -rf /var/lib/postgresql/9.3/main/postgresql.conf \
    /var/lib/postgresql/9.3/main/pg_hba.conf \
    /var/lib/postgresql/9.3/main/pg_ident.conf

## 4. restart service
service postgresql start
EOF

######: repmgr: Create the directory & conf for repmgr
sudo su - postgres -c "mkdir -p /var/lib/postgresql/repmgr/"
sudo su - postgres -c "cat > /var/lib/postgresql/repmgr/repmgr.conf <<EOF
cluster=my_pgsql_cluster
node=2
node_name=$CURRENT_NODE_NAME

conninfo='host=$CURRENT_NODE_ADDRESS user=repmgr_usr dbname=repmgr_db'
pg_bindir=/usr/lib/postgresql/9.3/bin
master_response_timeout=5

reconnect_attempts=2
reconnect_interval=2

failover=manual
promote_command='/usr/bin/repmgr standby promote -f /var/lib/postgresql/repmgr/repmgr.conf'
follow_command='/usr/bin/repmgr standby follow -f /var/lib/postgresql/repmgr/repmgr.conf'
EOF"

######: 
# chown -R postgres:postgres /var/lib/pgsql/.ssh /var/lib/pgsql/.pgpass /var/lib/pgsql/repmgr
chown -R postgres:postgres /var/lib/postgresql/repmgr

service postgresql --full-restart

# repmgr: Register the master node with repmgr
sudo su - postgres -c "/usr/bin/repmgr -f /var/lib/postgresql/repmgr/repmgr.conf --verbose standby register"
sudo su - postgres -c "service postgresql --full-restart"
```

Balancer-Common: the pgpool server installation (common for primary/secondary node):

``` shell
#!/bin/sh
# shell script for pg-balancer

if [ $1 = "" ] || [ $2 = "" ]; then
    echo "2 Params can not be empty."
    exit -1;
fi

# DEFAULT_MASTER_HOST_ADDRESS=192.168.3.11
CURRENT_BALANCER_ADDRESS=$1
echo $CURRENT_BALANCER_ADDRESS
CURRENT_BALANCER_NAME=pg-balancer-1

CURRENT_BALANCER_ADDRESS_2=$2
echo $CURRENT_BALANCER_ADDRESS_2
CURRENT_BALANCER_NAME_2=pg-balancer-2

# Add the APT repository of PostgreSQL packages for Debian and Ubuntu
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update

# Install: basic
sudo apt-get -y --force-yes install sshpass
# Install PostgreSQL 9.3 (Server, Client)
sudo apt-get -y --force-yes install postgresql-client-9.3 postgresql-client-common
sudo apt-get -y --force-yes install pgpool2 postgresql-9.3-pgpool2
# Checking: if postgresql service has been succefully installed
sudo service postgresql status

chown -R postgres:postgres /etc/pgpool2/

# ========: Updating: /etc/pgpool2/pgpool.conf
THE_PGPOOL_CONF="/etc/pgpool2/pgpool.conf"
sudo -u postgres bash <<EOF
set_conf () {
    local tkey=\$1; local tvalue=\$2; local tfile=\$3
    sed -i.bak -e "s/^#*\\s*\\(\$tkey\\s*=\\s*\\).*\\\$/\\1\$tvalue/" \$tfile
    echo "===> set params completed: \$tkey, \$tvalue, \$tfile"
    return 0
}

echo "XXXXXXXXXX $THE_PGPOOL_CONF"
set_conf listen_addresses \'*\' $THE_PGPOOL_CONF
set_conf port 9999 $THE_PGPOOL_CONF
set_conf enable_pool_hba on $THE_PGPOOL_CONF
set_conf pool_passwd \'pool_password\' $THE_PGPOOL_CONF
set_conf connection_cache off $THE_PGPOOL_CONF
set_conf replication_mode off $THE_PGPOOL_CONF
set_conf replicate_select off $THE_PGPOOL_CONF
set_conf load_balance_mode on $THE_PGPOOL_CONF
set_conf master_slave_mode on $THE_PGPOOL_CONF
set_conf master_slave_sub_mode \'stream\' $THE_PGPOOL_CONF
# follow_master_command
set_conf follow_master_command "'\/etc\/pgpool2\/follow_master_command.sh %d %h'" $THE_PGPOOL_CONF

set_conf sr_check_user \'pgpool_usr\' $THE_PGPOOL_CONF
set_conf wd_lifecheck_user \'pgpool_usr\' $THE_PGPOOL_CONF

set_conf health_check_period 10 $THE_PGPOOL_CONF
set_conf health_check_user \'pgpool_usr\' $THE_PGPOOL_CONF
set_conf health_check_password \'a\' $THE_PGPOOL_CONF
set_conf failover_command "'\/etc\/pgpool2\/failover_stream.sh %d %H\'" $THE_PGPOOL_CONF

set_conf recovery_user \'pgpool_usr\' $THE_PGPOOL_CONF
set_conf recovery_password \'a\' $THE_PGPOOL_CONF
set_conf recovery_1st_stage_command \'basebackup.sh\' $THE_PGPOOL_CONF

set_conf backend_hostname0 \'192.168.3.11\' $THE_PGPOOL_CONF
set_conf backend_port0 5432 $THE_PGPOOL_CONF
set_conf backend_weight0 1 $THE_PGPOOL_CONF
set_conf backend_data_directory0 "'\/var\/lib\/postgresql\/9.3\/main\'" $THE_PGPOOL_CONF
set_conf backend_flag0 \'ALLOW_TO_FAILOVER\' $THE_PGPOOL_CONF

set_conf backend_hostname1 \'192.168.3.12\' $THE_PGPOOL_CONF
set_conf backend_port1 5432 $THE_PGPOOL_CONF
set_conf backend_weight1 1 $THE_PGPOOL_CONF
set_conf backend_data_directory1 "'\/var\/lib\/postgresql\/9.3\/main\'" $THE_PGPOOL_CONF
set_conf backend_flag1 \'ALLOW_TO_FAILOVER\' $THE_PGPOOL_CONF

# set_conf backend_hostname2 \'192.168.3.13\' $THE_PGPOOL_CONF
# set_conf backend_port2 5432 $THE_PGPOOL_CONF
# set_conf backend_weight2 1 $THE_PGPOOL_CONF
# set_conf backend_data_directory2 "'\/var\/lib\/postgresql\/9.3\/main\'" $THE_PGPOOL_CONF
# set_conf backend_flag2 \'ALLOW_TO_FAILOVER\' $THE_PGPOOL_CONF

# Watchdog:
# Watchdog: Enabling watchdog
set_conf use_watchdog on $THE_PGPOOL_CONF
# Watchdog: Virtual IP
set_conf delegate_IP \'192.168.1.100\' $THE_PGPOOL_CONF
# Watchdog: Watchdog hostname & port
set_conf wd_hostname \'$CURRENT_BALANCER_ADDRESS\' $THE_PGPOOL_CONF
set_conf wd_port 9000 $THE_PGPOOL_CONF
# Watchdog: Paths for commands to control virtual IP
set_conf ifconfig_path "'\/sbin'" $THE_PGPOOL_CONF
set_conf arping_path "'\/usr\/sbin'" $THE_PGPOOL_CONF
# Watchdog: Lifechek method
set_conf wd_lifecheck_method \'heartbeat\' $THE_PGPOOL_CONF
# Watchdog: Lifechek intereval
set_conf wd_interval 3 $THE_PGPOOL_CONF
# Watchdog: Heartbeat settings
set_conf wd_heartbeat_port 9694 $THE_PGPOOL_CONF
set_conf heartbeat_destination0 \'$CURRENT_BALANCER_ADDRESS_2\' $THE_PGPOOL_CONF
set_conf heartbeat_destination_port0 9694 $THE_PGPOOL_CONF
# Watchdog: pgpool-II to be monitored
set_conf other_pgpool_hostname0 \'$CURRENT_BALANCER_ADDRESS_2\' $THE_PGPOOL_CONF
set_conf other_pgpool_port0 9999 $THE_PGPOOL_CONF
set_conf other_wd_port0 9000 $THE_PGPOOL_CONF
EOF


# sudo mkdir /var/www/.ssh
# sudo chown www-data:www-data /var/www/.ssh
# sudo chmod -R 750 /var/www/.ssh

# File: /etc/pgpool2/failover_stream.sh
#=============================================
sudo -u postgres sh <<\EOF
cat > /etc/pgpool2/failover_stream.sh <<\EOF2
#!/bin/sh
# Failover ocmmand for streaming replication.
#
# Arguments: $1: failed node id. $2: new master hostname.
 
failed_node=$1
new_master=$2
(
date
echo "Failed node: $failed_node, 1: $1, 2: $2"
set -x
# Promote standby/slave to be a new master (old master failed) 
sshpass -p 'a' /usr/bin/ssh -o StrictHostKeyChecking=no -T -l postgres -i /var/lib/postgresql/.ssh/id_rsa $new_master "/usr/bin/repmgr -f /var/lib/postgresql/repmgr/repmgr.conf standby promote 2>/dev/null 1>/dev/null <&-"
exit 0;
) 2>&1 | tee -a /tmp/failover_stream.sh.log
EOF2
EOF

sudo -u postgres sh <<\EOF
chown -R postgres:postgres /etc/pgpool2/failover_stream.sh
chmod 755 /etc/pgpool2/failover_stream.sh
EOF


# File: /etc/pgpool2/follow_master_command.sh
#=============================================
sudo -u postgres sh <<\EOF
cat > /etc/pgpool2/follow_master_command.sh <<\EOF2
#!/bin/sh
# Follow master command for streaming replication.
 
node_id=$1
node_hostname=$2
(
date
echo "Follow master node: $node_id, 1: $1, 2: $2"
set -x

# Update the standby/slave to follow the new master
sshpass -p 'a' /usr/bin/ssh -o StrictHostKeyChecking=no -T -l postgres -i /var/lib/postgresql/.ssh/id_rsa $node_hostname "/usr/bin/repmgr -f /var/lib/postgresql/repmgr/repmgr.conf standby follow 2>/dev/null 1>/dev/null <&-"

# wait few seconds for following to be completed, and then re-attach the node to pgpool
sleep 30
pcp_detach_node 0 localhost 9898 pgpool_usr a $node_id
pcp_attach_node 0 localhost 9898 pgpool_usr a $node_id

exit 0;
) 2>&1 | tee -a /tmp/follow_master_command.sh.log
EOF2
EOF

sudo -u postgres sh <<\EOF
chown -R postgres:postgres /etc/pgpool2/follow_master_command.sh
chmod 755 /etc/pgpool2/follow_master_command.sh
EOF

# Updating: pg_hba.conf
#=============================================
sudo -u postgres sh <<EOF
cat >> /etc/pgpool2/pool_hba.conf <<EOFcat
# tw:
host    all         all         0.0.0.0/0             md5
EOFcat
EOF

# Every user that needs to connect via pgpool needs to be added in pool_passwd. First we need to 
# create this file and let it be owned by postgres:
sudo -u postgres sh <<\EOF
rm -rf /etc/pgpool2/pool_password
touch /etc/pgpool2/pool_password
chown postgres:postgres /etc/pgpool2/pool_password
EOF

# add users to the file. Let’s do that for the pgpool-user which we created earlier:
sudo -u postgres sh <<\EOF
pg_md5 -m -u pgpool_usr a
pg_md5 -m -u postgres a
pg_md5 -m -u ugis ugis
EOF

# Last step is to allow connection via PCP to manage pgpool. This requires a similar approach as 
# with pool_password:
sudo -u postgres sh <<\EOF
rm -rf /etc/pgpool2/pcp.conf
touch /etc/pgpool2/pcp.conf
echo "pgpool_usr:$(pg_md5 a)" | tee -a /etc/pgpool2/pcp.conf
echo "postgres:$(pg_md5 a)" | tee -a /etc/pgpool2/pcp.conf
echo "ugis:$(pg_md5 ugis)" | tee -a /etc/pgpool2/pcp.conf
EOF


#############################################
# Install pgpoolAdmin
#############################################

# Install: HTTP Server(Apache)
sudo apt-get -y --force-yes install apache2
# Install: PHP4.4.2 and higher
sudo apt-get -y --force-yes install php5 libapache2-mod-php5
sudo apt-get -y --force-yes install php5-pgsql
# sudo service apache2 restart
sudo /etc/init.d/apache2 restart
# Install: pgpool (Already done)

# the apache2 is using user www-data
# adding www-data to postgres group, $ id www-data, so the web-application can start pgpool and write log
sudo usermod -a -G postgres www-data

# x
PGPOOL_ADMIN_TOOL=pgpooladmin-tool
wget http://www.pgpool.net/download.php?f=pgpoolAdmin-3.4.1.tar.gz
mv download.php\?f\=pgpoolAdmin-3.4.1.tar.gz pgpoolAdmin-3.4.1.tar.gz

# sudo tar xzf pgpoolAdmin-3.4.1.tar.gz -C /var/www/html/$PGPOOL_ADMIN_TOOL
sudo tar xzf pgpoolAdmin-3.4.1.tar.gz
sudo mv pgpoolAdmin-3.4.1 $PGPOOL_ADMIN_TOOL
sudo rm -rf /var/www/html/$PGPOOL_ADMIN_TOOL
sudo mv $PGPOOL_ADMIN_TOOL /var/www/html/

sudo chmod 777 /var/www/html/$PGPOOL_ADMIN_TOOL/templates_c

sudo chown www-data /var/www/html/$PGPOOL_ADMIN_TOOL/conf/pgmgt.conf.php
sudo chmod 644 /var/www/html/$PGPOOL_ADMIN_TOOL/conf/pgmgt.conf.php
sudo chmod 777 /var/www/html/$PGPOOL_ADMIN_TOOL/conf/pgmgt.conf.php

sudo chown www-data /etc/pgpool2/pgpool.conf
sudo chmod 644 /etc/pgpool2/pgpool.conf
sudo chown www-data /etc/pgpool2/pcp.conf
sudo chmod 644 /etc/pgpool2/pcp.conf
sudo chown www-data /etc/pgpool2/pool_password
sudo chmod 644 /etc/pgpool2/pool_password
sudo chmod 755 /usr/sbin/pgpool
sudo chmod 755 /usr/sbin/pcp_*

### Upate pgpoolAdmin config
THE_PGMGT_CONF=/var/www/html/$PGPOOL_ADMIN_TOOL/install/defaultParameter.php
sudo sed -i "s@define(\"_PGPOOL2_CONFIG_FILE\", \"/usr/local/etc/pgpool.conf\");@define(\"_PGPOOL2_CONFIG_FILE\", \"/etc/pgpool2/pgpool.conf\");@g" $THE_PGMGT_CONF
sudo sed -i "s@define(\"_PGPOOL2_PASSWORD_FILE\", \"/usr/local/etc/pcp.conf\");@define(\"_PGPOOL2_PASSWORD_FILE\", \"/etc/pgpool2/pcp.conf\");@g" $THE_PGMGT_CONF
sudo sed -i "s@define(\"_PGPOOL2_COMMAND\", \"/usr/local/bin/pgpool\");@define(\"_PGPOOL2_COMMAND\", \"/usr/sbin/pgpool\");@g" $THE_PGMGT_CONF
sudo sed -i "s@define(\"_PGPOOL2_PCP_DIR\", \"/usr/local/bin\");@define(\"_PGPOOL2_PCP_DIR\", \"/usr/sbin\");@g" $THE_PGMGT_CONF

# sudo service apache2 restart
sudo /etc/init.d/apache2 restart
```

Balancer-Primary: Configured in vagrant file

``` vagrant
# tw-pg-balancer.sh 192.168.3.5 192.168.3.6
config.vm.provision "shell" do |sh|
  sh.path = "../my-postgresql-cluster/tw-pg-balancer.sh"
  sh.args = "192.168.3.5 192.168.3.6"
end
```

Balancer-Secondary: Configured in vagrant file

``` vagrant
# tw-pg-balancer.sh 192.168.3.6 192.168.3.5
config.vm.provision "shell" do |sh|
  sh.path = "../my-postgresql-cluster/tw-pg-balancer.sh"
  sh.args = "192.168.3.6 192.168.3.5"
end
```

## Misc


--------

[img-1-network-diagram]: resource/img-1-network-diagram.png
