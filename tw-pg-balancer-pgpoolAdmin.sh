#!/bin/sh

# Install: HTTP Server(Apache)
sudo apt-get -y --force-yes install apache2
# Install: PHP4.4.2 and higher
sudo apt-get -y --force-yes install php5 libapache2-mod-php5
sudo apt-get -y --force-yes install php5-pgsql
# sudo service apache2 restart
sudo /etc/init.d/apache2 restart
# Install: pgpool (Already done)

# the apache2 is using user www-data
# adding www-data to postgres group, $ id www-data, so the web can start pgpool and write log
usermod -a -G postgres www-data

# x
PGPOOL_ADMIN_TOOL=pgpooladmin-tool
sudo wget http://www.pgpool.net/download.php?f=pgpoolAdmin-3.4.1.tar.gz
sudo mv download.php\?f\=pgpoolAdmin-3.4.1.tar.gz pgpoolAdmin-3.4.1.tar.gz
tar xzf pgpoolAdmin-3.4.1.tar.gz $PGPOOL_ADMIN_TOOL

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

sudo rm -rf /var/www/html/$PGPOOL_ADMIN_TOOL/install


# ====
# http://192.168.3.5/pgpooladmin-tool/install/phpinfo.php
# http://192.168.3.5/pgpooladmin-tool/install/index.php
# sudo rm -rf pgpooladmin-tool/
# sudo chmod -R 777 pgpooladmin-tool/








