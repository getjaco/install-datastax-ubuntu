#!/usr/bin/env bash

echo "Running install-datastax/bin/dse.sh"

cloud_type=$1
seed_nodes_dns_names=$2
data_center_name=$3
opscenter_dns_name=$4
cluster_name=$5
solr_enabled="0"
max_solr_concurrency_per_core="2"

if [[ "$6" == "1" ]]; then
  solr_enabled=$6
fi
if [[ "$7" == "1" ]]; then
  solr_enabled=$7
fi


# Assuming only one seed is passed in for now
seed_node_dns_name=$seed_nodes_dns_names

# On GKE we resolve to a private IP.
# On AWS and Azure this gets the public IP.
# On GCE it resolves to a private IP that is globally routeable in GCE.
if [[ $cloud_type == "gke" ]]; then
  seed_node_ip=`getent hosts $seed_node_dns_name | awk '{ print $1 }'`
  opscenter_ip=`getent hosts $opscenter_dns_name | awk '{ print $1 }'`
elif [[ $cloud_type == "gce" ]]; then
  # If the IP isn't up yet it will resolve to "" on GCE

  seed_node_ip=""
  while [ "${seed_node_ip}" == "" ]; do
    seed_node_ip=`dig +short $seed_node_dns_name`
  done

  opscenter_ip=""
  while [ "${opscenter_ip}" == "" ]; do
    opscenter_ip=`dig +short $opscenter_dns_name`
  done
elif [[ $cloud_type == "azure" ]]; then
  # If the IP isn't up yet it will resolve to 255.255.255.255 on Azure

  seed_node_ip="255.255.255.255"
  while [ "${seed_node_ip}" == "255.255.255.255" ]; do
    seed_node_ip=`dig +short $seed_node_dns_name`
  done

  opscenter_ip="255.255.255.255"
  while [ "${opscenter_ip}" == "255.255.255.255" ]; do
    opscenter_ip=`dig +short $opscenter_dns_name`
  done
elif [[ $cloud_type == "aws" ]]; then
  seed_node_ip=`getent hosts $seed_node_dns_name | awk '{ print $1 }'`
  #opscenter_ip=`getent hosts $opscenter_dns_name | awk '{ print $1 }'`
  # Playing tricks and passing EIP instead of hostname
  opscenter_ip=$opscenter_dns_name
fi

if [[ $cloud_type == "gce" ]] || [[ $cloud_type == "gke" ]]; then
  # On Google private IPs are globally routable within GCE
  # We've also been seeing issues using the public ones for broadcast.
  # So, we're just going to use the private for everything.
  # We're still trying to figure out GKE, but only supporting 1 DC for now, so this ought to work.
  node_broadcast_ip=`echo $(hostname -I)`
  node_ip=`echo $(hostname -I)`
else
  node_broadcast_ip=`curl --retry 10 icanhazip.com`
  node_ip=`echo $(hostname -I)`
fi

seed_node_ip=$(./dse/get_seed_node_ip.py | tr -d '\n')

echo "Configuring nodes with the settings:"
echo cloud_type \'$cloud_type\'
echo data_center_name \'$data_center_name\'
echo seed_node_ip \'$seed_node_ip\'
echo node_broadcast_ip \'$node_broadcast_ip\'
echo node_ip \'$node_ip\'
echo opscenter_ip \'$opscenter_ip\'

#### Ok, now let's starting making changes to the system...

./os/install_java.sh

# OpsCenter uses iostat and Ubuntu 14.04 LTS doesn't seem to have it installed by default.
sudo apt-get -y install sysstat
./dse/install.sh $cloud_type
./dse/configure_cassandra_rackdc_properties.sh $cloud_type $data_center_name
./dse/configure_cassandra_yaml.sh $node_ip $node_ip $seed_node_ip $cluster_name
./dse/configure_default_dse.sh $solr_enabled
./dse/configure_dse_yaml.sh $max_solr_concurrency_per_core
./dse/configure_dse_recommended.sh
./dse/configure_agent_address_yaml.sh $node_ip $node_broadcast_ip $opscenter_ip
# Add JMX-Exporter to cassandra
echo 'JVM_OPTS="$JVM_OPTS -javaagent:/usr/share/jmx-exporter/jmx_prometheus_javaagent-0.3.0.jar=7070:/usr/share/jmx-exporter/cassandra.yml"' | sudo tee --append /etc/dse/cassandra/cassandra-env.sh

# Changing Dump dir
mkdir /var/lib/cassandra/dump
sed -i '0,/.*CASSANDRA_HEAPDUMP_DIR.*/s/.*CASSANDRA_HEAPDUMP_DIR.*/export CASSANDRA_HEAPDUMP_DIR="\/var\/lib\/cassandra\/dump"\n&/' /etc/dse/cassandra/cassandra-env.sh

# Start DSE
./dse/start.sh

# It looks like DSE might be setting the keepalive to 300.  Need to confirm.
if [[ $cloud_type == "azure" ]]; then
  ./os/set_tcp_keepalive_time.sh
fi
