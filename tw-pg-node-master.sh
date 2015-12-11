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
host    all             all  	        127.0.0.1/32            trust
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


######: 
# sed -i.bak \
# -e "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" \
# -e "" \
# /etc/postgresql/9.3/main/postgresql.conf

# =======
# sudo su - postgres -c "cat > /var/lib/postgresql/icron-job-key-change-notification.conf <<\EOF
# sshpass -p 'a' scp -o StrictHostKeyChecking=no -r /var/lib/postgresql/.ssh/authorized_keys /var/lib/postgresql/.ssh/known_hosts 192.168.3.12:/var/lib/postgresql/.ssh
# EOF"
