#!/bin/sh
# shell script for pg-node-slave
DEFAULT_MASTER_HOST_ADDRESS=192.168.3.11
CURRENT_NODE_ADDRESS=192.168.3.12
CURRENT_NODE_NAME=pg-node-2

# Add the APT repository of PostgreSQL packages for Debian and Ubuntu
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update

# Install: basic
sudo apt-get -y --force-yes install sshpass
# Install PostgreSQL 9.3 (Server, Client)
sudo apt-get -y --force-yes install postgresql-9.3 postgresql-contrib-9.3
sudo apt-get -y --force-yes install postgresql-client-9.3 postgresql-client-common
sudo apt-get -y --force-yes install postgresql-9.3-repmgr
sudo apt-get -y --force-yes install postgresql-9.3-pgpool2
# Checking: if postgresql service has been succefully installed
sudo service postgresql status

# Change password to 'a' for user postgres
echo -e "a\na\n" | sudo passwd postgres

# Common functions:
set_conf () {
    local tkey=$1; local tvalue=$2; local tfile=$3
    sed -i.bak -e "s/^#*\s*\($tkey\s*=\s*\).*\$/\1$tvalue/" $tfile
    echo "===> set params completed: $tkey, $tvalue, $tfile"
    return 0
}

#=====================================

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

#=====================================

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

# repmgr: Create the directory & conf for repmgr
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

# chown -R postgres:postgres /var/lib/pgsql/.ssh /var/lib/pgsql/.pgpass /var/lib/pgsql/repmgr
chown -R postgres:postgres /var/lib/postgresql/repmgr

# repmgr: Register the master node with repmgr
sudo su - postgres -c "/usr/bin/repmgr -f /var/lib/postgresql/repmgr/repmgr.conf --verbose standby register"
sudo su - postgres -c "service postgresql --full-restart"


#========
# sshpass -p 'a' ssh -o StrictHostKeyChecking=no -t postgres@localhost

# # Set up trusted copy between the servers
# sudo -u postgres sh <<EOF
# ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
# ssh-copy-id -i ~/.ssh/id_rsa.pub $DEFAULT_MASTER_HOST_ADDRESS
# EOF

# sudo -u postgres sh <<EOF
# sh /var/lib/postgresql/icron-job-key-change-notification.conf
# EOF