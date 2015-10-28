# my-postgresql-cluster

The project to build my sample PostgreSQL cluster, using pgpool-II, with below features:
- Replication and Load Balancing,
- load balancing; 
- Replication; 
- online recovery; 
- with pgpoolAdmin (pgpoolAdmin is a management tool for pgpool-II written in PHP)

# The network diagram:

pg-balancer-1	192.168.3.5
pg-node-1 		192.168.3.11 (default master)
pg-node-2		192.168.3.12
pg-node-3		192.168.3.13

#Scripts:

tw-pg-balancer.sh (update balancer settings)
pgpool.conf

tw-pg-node-master.sh (update pg-node settings)
postgresql.conf.master

tw-pg-node-slave.sh (update pg-node settings)
postgresql.conf.slave

tw-pg-recovery.sh
recovery.conf

tw-failover.sh
tw-online-recovery.sh
tw-streaming-replication.sh

# Master, Script & Config

# Slave, Script & Config

# Balancer, pgpool server, Script & Config
