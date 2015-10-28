#!/bin/sh
# shell script for pg-balancer
DEFAULT_MASTER_HOST_ADDRESS=192.168.3.11
CURRENT_BALANCER_ADDRESS=192.168.3.5
CURRENT_BALANCER_NAME=pg-balancer-1

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

#=====================================

# Set up trusted copy between the servers
# One option at this point, to setup public key authentication, would be to repeat the steps as we 
# did for root. But I’ll just reuse the generated keys, known_hosts and authorized_keys from root 
# and use them for user postgres:
sudo su - postgres -c sh <<EOF
# generate a new RSA-keypair, # ssh-copy-id -i ~/.ssh/id_rsa.pub <slave hostname>
ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
chmod 740 .ssh/

# remote-adding authorized_keys: add the generated public keys of current slave to master ~/.ssh/authorized_keys
sshpass -p 'a' ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub $DEFAULT_MASTER_HOST_ADDRESS

# remote-adding known_hosts, ssh-keyscan -H 192.168.3.12 | sudo tee ~/.ssh/known_hosts
# sshpass -p 'a' ssh -t postgres@$DEFAULT_MASTER_HOST_ADDRESS "sshpass -p 'a' ssh -o StrictHostKeyChecking=no postgres@$CURRENT_NODE_ADDRESS"
# ssh-keygen -f "/var/lib/postgresql/.ssh/known_hosts" -R 192.168.3.12
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

#============Switching user: postgres
sshpass -p 'a' ssh -o StrictHostKeyChecking=no -t postgres@localhost

set_conf () {
    local tkey=$1; local tvalue=$2; local tfile=$3
    sed -i.bak -e "s/^#*\s*\($tkey\s*=\s*\).*\$/\1$tvalue/" $tfile
    echo "===> set params completed: $tkey, $tvalue, $tfile"
    return 0
}

# Updating: /etc/pgpool2/pgpool.conf
THE_PGPOOL_CONF="/etc/pgpool2/pgpool.conf"
set_conf listen_addresses \'*\' $THE_PGPOOL_CONF
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

set_conf backend_hostname2 \'192.168.3.13\' $THE_PGPOOL_CONF
set_conf backend_port2 5432 $THE_PGPOOL_CONF
set_conf backend_weight2 1 $THE_PGPOOL_CONF
set_conf backend_data_directory2 "'\/var\/lib\/postgresql\/9.3\/main\'" $THE_PGPOOL_CONF
set_conf backend_flag2 \'ALLOW_TO_FAILOVER\' $THE_PGPOOL_CONF

exit
#============Switching user: postgres

sudo mkdir /var/www/.ssh
sudo chown www-data:www-data /var/www/.ssh
sudo chmod -R 750 /var/www/.ssh

# File: /etc/pgpool2/failover_stream.sh
#=============================================
sudo -u postgres sh <<\EOF
cat > /etc/pgpool2/failover_stream.sh <<\EOF2
#!/bin/sh
# Failover command for streaming replication.
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

#=============================================
# Updating: pg_hba.conf
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
rm -rf pcp.conf
touch pcp.conf
echo "pgpool_usr:$(pg_md5 a)" | tee -a /etc/pgpool2/pcp.conf
echo "postgres:$(pg_md5 a)" | tee -a /etc/pgpool2/pcp.conf
echo "ugis:$(pg_md5 ugis)" | tee -a /etc/pgpool2/pcp.conf
EOF


#===

# repmgr: Add users (todo: replace 'admin' using postgres)
#sudo -u postgres psql -c "CREATE ROLE pgpool_usr SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION LOGIN ENCRYPTED PASSWORD 'a';"