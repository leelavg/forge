#!/bin/bash
# Copy ssh key to remove server
# Usage: ./ssh_copy_id <FILE_NAME> <PATTERN> <PASSWORD>
# Use case: IP is mapped to hostname in /etc/hosts and hosts file is used

file=$1
filter=$2
pass=$3
for name in `cat $file`; do
    if [[ $name =~ $filter ]]; then
        sshpass -p $pass ssh-copy-id -o StrictHostKeyChecking=no root@$name
    fi
done
