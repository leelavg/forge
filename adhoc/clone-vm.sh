#!/bin/bash

# Please change paths according to your setup
# BEGIN - Existing base image
# END - Create VMs from base image and write IPs to hostsfile

# $1=base_vm; $2=vm_prefix; $3=num_vms; $4=num_disks; $5=disk_size
# ./clone-vm.sh centos7-34 7-34 6 7 25G

# Required RPMs on KVM :
# yum install virt libvirt libvirt-python libvirt-client libguestfs libguestfs-tools
# yum groupinstall virtualization-client virtualization-platform virtualization-tools
# yum expect

# Make sure you create a file named `password.txt` in script's directory with plain password of base VM as the content (manual)
[ ! -f password.txt ] && echo "No password.txt file exists in current directory" && exit -1

# IMP: Run below `startup.sh` in the base image before cloning (manual)
# Copy SSH key too for easy login into new VMs
cat << 'EOF' > startup.sh
#!/bin/bash

# Enable console access for every VM
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

# Script to be run when VMs are booting for the first time (automatic)
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

# To get IPs of hosts without logging in from virt-manager (automatic)
cat << 'EOF' > get_ip.exp
#!/usr/bin/expect -f
set timeout 5
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
send "exit\n"
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

# centos8 base on centos7 KVM conflicts with XFS file system forward compatibility
host_ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
guest_ver=$(echo $(virt-cat -d $base_vm /etc/system-release-cpe) | awk -F':' '{print $5}')
# Pool path, (if not using default path, it should be change below accordingly or
# for any complex path directly declare it i.e, pool_path=<COMPLEX_PATH>)
pool_path=$(virsh pool-dumpxml default | grep -Po '(?<=path>)[[:alnum:]/.-]+(?=<)')
if [[ $host_ver =~ ^7 && $guest_ver =~ ^8 ]]; then
    cd $pool_path
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

vm_names=()
for i in `seq 1 $num_vms`
do
    vm_names+=("${vm_prefix}${i}")
done

for name in ${vm_names[@]}
do
    # Clone
    virt-clone --original $base_vm --name $name --auto-clone

    # Prep the clone
    # if `--selinux-relabel` is removed then `firshboot` script will not be trigerred
    virt-sysprep -d $name --selinux-relabel --enable $ops --firstboot ./change_uuid.sh

    # Set VM autostart
    virsh autostart $name

    # Start VM and attach disks
    virsh start $name

    Create and attach disks
    for i in `seq 1 $num_disks`
    do
        qemu-img create -o preallocation=metadata -f qcow2 $pool_path/"$name-$i" $disk_size
        sleep .2
        virsh attach-disk $name --source $pool_path/"$name-$i" --target vd${dict[$i]} --driver qemu --subdriver qcow2 --persistent
    done
done


echo "Writing IP addresses of newly created VMs to 'hostsfile'"
echo "# VMs from base VM $base_vm" > hostsfile
for name in ${vm_names[@]}
do
    # Write IP in hostsfiles
    count=1
    while ! grep -q ${name/-/} hostsfile
    do
        expect get_ip.exp $name  | grep -A 1 hostname | grep -Po '\d+\.\d+\.\d+\.\d+' | awk -v name=$name '{gsub("-","",name); print $1, name}' >> hostsfile;
        if [ $count -eq 2 ]; then break; fi;
        ((count++))
    done
done

# Extra
# pool_path=$(virsh pool-dumpxml default | grep -Po '(?<=path>)[[:alnum:]/.-]+(?=<)')
# for i in `virsh list --all | grep -vP 'centos|Name|leela|--' | awk '{print $2}'`; do virsh destroy $i; virsh undefine $i; rm -f $pool_path/$i*; done;
