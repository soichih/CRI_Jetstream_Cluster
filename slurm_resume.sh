#!/bin/bash

source /etc/slurm/openrc.sh

node_size="m1.small"
node_image=$(openstack image list -f value | grep -i ${OS_USERNAME}-compute-image- | cut -f 2 -d' '| head -n 1)
key_name="${OS_USERNAME}-${OS_PROJECT_NAME}-slurm-key"
network_name=${OS_USERNAME}-elastic-net
log_loc=/var/log/slurm/slurm_elastic.log

echo "Node resume invoked: $0 $*" >> $log_loc

#useradd won't do anything if the user exists. 
echo "#!/bin/bash" > /tmp/add_users.sh
cat /etc/passwd | awk -F':' '$4 >= 1001 && $4 < 65000 {print "useradd -M -u", $3, $1}' >> /tmp/add_users.sh

#First, loop over hosts and run the openstack create/resume commands for *all* resume hosts at once.
#Avoids getting stuck if one host fails?
ansible_list=""
for host in $(scontrol show hostname $1)
do
  echo "$host ansible_user=centos ansible_become=true" >> /etc/ansible/hosts

  echo "openstack server create $host --flavor $node_size --image $node_image --key-name $key_name --user-data <(cat /etc/slurm/prevent-updates.ci && echo -e "hostname: $host \npreserve_hostname: true\ndebug:") --security-group global-ssh --security-group cluster-internal --nic net-id=$network_name" >> $log_loc

    node_status=$(openstack server create $host \
    --flavor $node_size \
    --image $node_image \
    --key-name $key_name \
    --user-data <(cat /etc/slurm/prevent-updates.ci && echo -e "hostname: $host \npreserve_hostname: true\ndebug:") \
    --security-group ${OS_USERNAME}-global-ssh --security-group ${OS_USERNAME}-cluster-internal \
    --nic net-id=$network_name 2>&1 \
    | tee -a $log_loc | awk '/status/ {print $4}')
    
    echo "$host status is: $node_status" >> $log_loc
done

#Now, check that hosts are up
for host in $(scontrol show hostname $1)
do
  until [[ $node_status == "ACTIVE" ]]; do
    sleep 3
    node_status=$(openstack server show $host 2>&1 | awk '/status/ {print $4}')
    echo "$host status is: $node_status" >> $log_loc
  done
   
  new_ip=$(openstack server show $host | awk '/addresses/ {print gensub(/^.*=/,"","g",$4)}')
  echo "$host ip is $new_ip" >> $log_loc
  sleep 10 # to give sshd time to be available
  ip_check=$(grep $new_ip /etc/hosts)
  host_check=$(grep $host /etc/hosts)
  if [[ -n $ip_check && ! ( $ip_check =~ $host ) ]]; then
   echo "OVERLAPPING ENTRY FOR $new_ip of $host in /etc/hosts: $ip_check" >> $log_loc
   exit 2
  fi
  if [[ -z $host_check ]]; then
    echo "$new_ip $host" >> /etc/hosts
  fi
  if [[ -n $host_check && ! ( $host_check =~ $new_ip ) ]]; then
    sed "s/.*$host.*/$new_ip $host/" /etc/hosts
  fi
  test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
  #  echo "test1: $test_hostname"
  until [[ -n $test_hostname ]]; do
    sleep 2
    test_hostname=$(ssh -q -F /etc/ansible/ssh.cfg centos@$host 'hostname' | tee -a $log_loc)
  done

  #reset the hostname JIC
  hostname_set_result=$(ansible -m hostname -a "name=$host" $host)
  #add users Just in Case
  user_add_result=$(ansible -m script -a "/tmp/add_users.sh" $host)
  #echo "Tried to add users: " $user_add_result >> $log_loc
  hosts_add_result=$(ansible -m copy -a "src=/etc/hosts dest=/etc/hosts" $host)
  #echo "Tried to add hosts $hosts_add_result" >> $log_loc
  slurm_sync_result=$(ansible -m copy -a "src=/etc/slurm/slurm.conf dest=/etc/slurm/slurm.conf" $host)
  #echo "Tried to sync slurm.conf $slurm_sync_result" >> $log_loc

#Now, safe to update slurm w/ node info
  scontrol update nodename=$host nodeaddr=$new_ip >> $log_loc

done

#if [[ -n $ansible_list ]]; then
#  echo "Running ansible on ${ansible_list::-1}" >> $log_loc
#  ansible-playbook -l "${ansible_list::-1}" /etc/slurm/compute_playbook.yml >> $log_loc
#fi
