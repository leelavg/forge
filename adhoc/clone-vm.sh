#!/bin/bash

# Please change paths according to your setup
# BEGIN - Existing base image
# END - Create VMs from base image and write IPs to hostsfile

# $1=base_vm; $2=vm_prefix; $3=num_vms; $4=num_disks; $5=disk_size
# ./clone-vm.sh rhel7-34 7-34 6 7 25G

# Required RPMs on KVM :
# yum install virt libvirt libvirt-python libvirt-client libguestfs libguestfs-tools
# yum groupinstall virtualization-client virtualization-platform virtualization-tools
# yum expect

# IMP: Run below `startup.sh` in the base image before cloning
cat << 'EOF' > startup.sh
#!/bin/bash

# Enalble console access for every VM
systemctl enable serial-getty@ttyS0.service
systemctl start serial-getty@ttyS0.service

# Make interface comeup automatically
ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
iface=$([[ $ver =~ ^7 ]] && echo eth0 || echo ens3)
sed -i 's/ONBOOT=no/ONBOOT=yes/' /etc/sysconfig/network-scripts/ifcfg-$iface

# virt-sysprep is still leaving some UUIDs
# Replace UUID of boot partition with actual disk name
disk=$(df -k /boot --output=source | tail -n 1)
cp -f /etc/fstab /etc/fstab.uuid
sed -r "/boot/ s|^UUID=[[:xdigit:]-]+|$disk|" /etc/fstab.uuid > /etc/fstab

EOF

# Script to be run when VMs are booting for the first time
cat << 'EOF' > change_uuid.sh
#!/bin/bash

# Set a new UUID for network interface
ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
iface=$([[ $ver =~ ^7 ]] && echo eth0 || echo ens3)
uuid=$(uuidgen $iface)
sed -ir "s/^UUID=.*/UUID=$uuid/" /etc/sysconfig/network-scripts/ifcfg-$iface

# Replace boot parition disk with UUID in fstab
disk=$(grep boot /etc/fstab | awk '{print $1}')
uuid=$(blkid $disk -o export | grep ^UUID)
cp -f /etc/fstab /etc/fstab.disk
sed -r "/boot/ s|$disk|$uuid|" /etc/fstab.disk > /etc/fstab

EOF

# To get IPs of hosts without logging in from virt-manager
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

chmod +x startup.sh get_ip.exp change_uuid.sh

# A base VM with all required packages and SSH-Keys installed (if needed) should exist and shut off
base_vm=$1
vm_prefix=$2
num_vms=$3
num_disks=$4
disk_size=$5

# RHEL8 base on RHEL7 KVM conflicts with XFS file system forward compatibility
host_ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
guest_ver=$(echo $(virt-cat -d $base_vm /etc/system-release-cpe) | awk -F':' '{print $5}')
# Pool path
pool=$(virsh pool-dumpxml default | grep -Po '(?<=path>)[[:alnum:]/.-]+(?=<)')
if [[ $host_ver =~ ^7 && $guest_ver =~ ^8 ]]; then
    cd $pool
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

for new_vm in `seq 1 $num_vms`
do
    name="${vm_prefix}${new_vm}"

    # Clone
    virt-clone --original $base_vm --name $name --auto-clone

    # Prep the clone
    # TODO: Seems firstboot isn't running, better run after login `sh /usr/lib/virt-sysprep/firsboot.sh start`
    virt-sysprep -d $name --enable $ops --firstboot ./change_uuid.sh

    # Set VM autostart
    virsh autostart $name

    # Start VM and attach disks
    virsh start $name

    # Dump the info of the machine
    virsh dominfo $name

    # Create and attach disks
    for i in `seq 1 $num_disks`
    do
        qemu-img create -o preallocation=metadata -f qcow2 $pool/"$name-$i" $disk_size
        sleep .2
        virsh attach-disk $name --source $pool/"$name-$i" --target vd${dict[$i]} --driver qemu --subdriver qcow2 --persistent
    done
done

# Get IPs of VMs and write to hosts file
# Run below after all VMs are up and running
# echo "# VMs from base image $base_image" > hostsfile
# for name in `virsh list --all | grep -vP 'rhel|Name|--' | awk '{print $2}'`; do ./get_ip.exp $name | sed -n '/hostname/{n;p;}' | awk -v name=$name '{gsub("-","",name); print $1, name}' >> hostsfile; done;
# sort -t' ' -k2 hostsfile > hosts
# mv -f hosts hostsfile

# Extra
# pool=$(virsh pool-dumpxml default | grep -Po '(?<=path>)[[:alnum:]/.-]+(?=<)')
# for i in `virsh list --all | grep -vP 'rhel|Name|--' | awk '{print $2}'`; do virsh destroy $i; virsh undefine $i; rm -f $pool/$i*; done;
