# Replication and load balancing of PostgreSQL, with repmgr and pgpool2
Using below tools:

**postgresql**: the dataabse server / client  
**repmgr**: the Replication Manager for PostgreSQL clusters  
**pgpool (with pgpoolAdmin3)**: for load balancing, failover control, pgpoolAdmin is a management tool for pgpool-II written in PHP

# my-postgresql-cluster
The project to build my sample PostgreSQL cluster, using pgpool-II, with below features:
- Replication
- Load balancing
- failover & online recovery

# The network:
* pg-balancer-1	192.168.3.5
* pg-balancer-1   192.168.3.5   (default master)
* pg-node-1       192.168.3.11  (default master)
* pg-node-2       192.168.3.12
* pg-node-3       192.168.3.13

主要的思路是：
> 所有机器之间使用public-key认证。  
> 使用一个Balancer和多个PG-Node，Node之间自由切换，保证只有一个Master。  
> PS:另一种选择是使用多个节点，每个节点上配置PostgreSQL + pgpool-with-(wtachdog)，
这样可以防止pgpool单点失败的情况

# Scripts:
The scripts is on github:https://github.com/fanyangxi/my-postgresql-cluster  
Notes (暂时在印象笔记中):  
~ PostgreSQL: 1-Replication, Cluster（集群模式）  
~ PostgreSQL: 2-pgpool2  
~ PostgreSQL: 3-repmgr  

### Balancer, pgpool server, Script & Config
tw-pg-balancer.sh (update balancer settings)  
tw-pg-balancer-pgpoolAdmin.sh  
pgpool.conf  

#### Master, Script & Config
tw-pg-node-master.sh (update pg-node settings)  
postgresql.conf.master  

### Slave, Script & Config
tw-pg-node-slave.sh (update pg-node settings)  
postgresql.conf.slave  

tw-recovery.sh  
tw-failover.sh  
tw-online-recovery.sh  
tw-streaming-replication.sh  

PostgreSQL pgpool-II of the Cluster Setup program (Partition + LoadBalance + Replication) - Database - Database Skill (有关于Parallel-Mode的介绍)  
~ http://www.databaseskill.com/4052440/  
~ http://blog.csdn.net/xtlog/article/details/4219353 (中文翻译版)
