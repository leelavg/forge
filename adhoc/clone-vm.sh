#!/bin/bash

# Please change paths according to your setup
# BEGIN - Existing base image
# END - Create VMs from base image and write IPs to hostsfile

# $1=base_image; $2=num_disks; $3=size_of_disk; $4=prefix
# ./clone-vm.sh rhel7-34 7 25G 7-34

# Required RPMs on KVM :
# yum install virt libvirt libvirt-python libvirt-client libguestfs libguestfs-tools
# yum groupinstall virtualization-client virtualization-platform virtualization-tools
# yum expect

# Make interface comeup automatically
# Better run startup.sh in the base image itself
cat << 'EOF' > startup.sh
#!/bin/bash
ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
iface=$([[ $ver =~ ^7 ]] && echo eth0 || echo ens3)
sed -i 's/ONBOOT=no/ONBOOT=yes/' /etc/sysconfig/network-scripts/ifcfg-$iface
systemctl enable serial-getty@ttyS0.service
systemctl start serial-getty@ttyS0.service
EOF

cat << 'EOF' > get_ip.exp
#!/usr/bin/expect -f
proc slurp {file} {
    set fh [open $file r]
    set ret [read $fh]
    close $fh
    return $ret
}
set password [slurp password.txt]
spawn virsh console $argv
expect "character"
send "\n"
expect "login: "
send "root\n"
expect "Password:"
send $password
expect "#"
send "hostname -I\n"
expect "#"
send "logout\n"
expect "login:"
send "^]\n"
exit 0
EOF

chmod +x startup.sh get_ip.exp

# A base VM with all required packages and SSH-Keys installed (if needed) should exist and shut off
# rhel7-34, 7, 25G
base_vm=$1
num_disks=$2
size=$3
prefix=$4

# For RHEL8 base image on RHEL7 KVM
if [[ $base_vm =~ rhel8 ]]; then
    cd /gluster
    if [ ! -d appliance ]; then
        curl -OL https://download.libguestfs.org/binaries/appliance/appliance-1.40.1.tar.xz
        tar xvfJ appliance-1.40.1.tar.xz
    fi
    export LIBGUESTFS_PATH=`pwd`/appliance/
    cd -
fi

# Options that needs to be enabled
ops=$(virt-sysprep --list-operations | grep -Pv 'ssh-userdir|ssh-hostkeys' | awk '{ printf "%s,", $1}' | sed 's/,$//')

declare -A dict
counter=1

# Disk mapping
for i in {b..z}
do
    dict["$counter"]=$i
    counter=`expr $counter + 1`
done

for new_vm in {1..6}
do

    for server in {$prefix-s,$prefix-gs}
    do
        name="${server}${new_vm}"

        # Clone
        virt-clone --original $base_vm --name $name --auto-clone

        # Prep the clone
        virt-sysprep -d $name --enable $ops --firstboot-command ./startup.sh

        # Set VM autostart
        virsh autostart $name

        # Start the VM
        virsh start $name

        # Dump the info of the machine
        virsh dominfo $name

        # Create and attach disks
        for i in `seq 1 $num_disks`
        do
            qemu-img create -o preallocation=metadata -f qcow2 /gluster/"$name-$i" $size
            sleep .2
            virsh attach-disk $name --source /gluster/"$name-$i" --target vd${dict[$i]} --driver qemu --subdriver qcow2 --persistent
        done


    done
done

# Get IPs of VMs and write to hosts file
# Run below after all VMs are up and running
# echo "# VMs from base image $base_image" > hostsfile
# for name in `virsh list --all | grep -vP 'rhel|Name|--' | awk '{print $2}'`; do ./get_ip.exp $name | sed -n '/hostname/{n;p;}' | awk -v name=$name '{gsub("-","",name); print $1, name}' >> hostsfile; done;
# sort -t' ' -k2 hostsfile > hosts
# mv -f hosts hostsfile

# Extra
# for i in `virsh list --all | grep -vP 'rhel|Name|--' | awk '{print $2}'`; do virsh destroy $i; virsh undefine $i; rm -f /gluster/$i*; done;
