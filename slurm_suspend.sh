#!/bin/bash

source ./openrc.sh

log_loc=/var/log/slurm_elastic.log

echo "Node suspend invoked: $0 $*" >> $log_loc

for host in $(scontrol show hostname $1)
do
  sed -i "s/$host//" /etc/ansible/hosts
  openstack server delete $host
done