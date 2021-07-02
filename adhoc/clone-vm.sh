#!/bin/bash

# Author: Leela Venkaiah G <lgangava@redhat.com>

# ===== STANDALONE SCRIPT ===== NO NEED TO CLONE WHOLE REPO =====

# Current Status: STABLE
# Total Steps [cloning VMs]: create_scripts, compatibility_check, perform_op
# Total Steps [Attaching disks]: attach_disks

# Sample usage:
# bash clone-vm.sh --base-vm=centos7-34 --prefix=7-34 --vms=3
# For help run: bash clone-vm.sh -h

# BEGIN - Existing base image
# END - Create VMs from base image and attach disks (optional)

# Required RPMs on KVM :
# yum install virt-install libvirt libvirt-client libguestfs libguestfs-tools bc expect

# Scope:
# - Clone a base VM (either ISO or PXE booted), attach disks
# - Thin base image results in faster cloning and prepping the clones
# - Minimum expectation from the script is:
#   - A matching base VM name as supplied in the arguments with no disks attached
#   - Shutdown the base VM after installing/tuning required (like copying SSH
#   keys, running startup.sh code block) settings
#   - Run the script with necessary arguments as stated in `Usage:`
#
# Cases covered in addition to cloning VM and attaching disks:
# - Force re-label SELinux labels
# - Support for cloning CentOS 8 base VM on CentOS 7 KVM (similar for RHEL)
# - Custom scripts on replacing correct UUIDs of disks and network interfaces
# - No deletion of VMs is happening and KVM by defaults prohibits overwrites of domain
# - Extra functionality: Attach disks to a guest VM
#
# Known limitations:
# - Only core functionality (clone VM, attach disks) is implemented
# - Experimental: take note of VMs IP, currently dumps ip address from arp cache
# - Checking for available space isn't implemented
# - No error recovery is inbuilt (just backoff if something goes wrong)

# Examples:
# 1. Single VM: `./clone-vm.sh --base-vm=rhel84 --prefix=84c --vms=1`
# 2. Single VM with same prefix: `./clone-vm.sh --base-vm=rhel84 --prefix=84c --vms=1 --start-index=2`
# 3. Two VMs with 2 disks attached to each VM: `./clone-vm.sh --base-vm=rhel84 --prefix=84s --vms=2 --disks=2`
# 4. Two VMs with 2 disks of 25G attached to each VM with same prefix and different start index: `./clone-vm.sh --base-vm=rhel84 --prefix=84s --vms=2 --disks=2 --start-index=3 --size=25G`
# 5. Attach 2 disks to an existing VM: `./clone-vm.sh --attach-disks=yes --prefix=84c --vms=1 --disks=2`
# 6. Attach 2 disks of 25G attached to each VM with same prefix and different start index: `./clone-vm.sh --attach-disks=yes --prefix=84c --vms=1 --disks=2 --start-index=2 --size=25G`
# Option --start-index is used to refer to starting VM (along with PREFIX) and value of --vms is added to this index to arrive at total number of VMs

# Notes:
# 1. Destroy and undefine VMs
# POOL_PATH=$(virsh pool-dumpxml default | grep -Po '(?<=path>).*?(?=<)')
# for i in `virsh list --all | awk '{print $2}' | grep -P '^(7|8)'`; do virsh destroy $i; virsh undefine $i; rm -f $POOL_PATH/$i*; done;
# 2. IPs of VMs:
# for vm in `virsh list --all | awk '{print $2}' | grep -P '^(7|8)'`; do expect -c "spawn virsh console $vm --force; expect \"Escape\"; send \"\r\"; expect \"login:\"; send \"^]\r\"; exit 0" | grep -Po 'dhcp.*?\s' | awk -v vm=$vm '{print $1, vm}'; done
#


# Break on any failure
set -e

BASE_VM=NULL
ATTACH_DISKS="no"
BASE_IP=NULL
PREFIX=NULL
START_INDEX=1
VMS=1
DISKS=0
SIZE="10G"
TEMP_DIR=$(mktemp -d)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pool path, (if not using default pool, it should be changed in below regex accordingly)
POOL_PATH=$(virsh pool-dumpxml default | grep -Po '(?<=path>).*?(?=<)')

# Char to index mapping
declare -A CHAR_MAP
value=1

for i in {a..z}
do
    CHAR_MAP["$i"]=$value
    value=$((value + 1))
done

# Dump everything to a log file
TIME=$(date +%b_%d_%y-%H-%M-%S)
exec 3<&1
coproc mytee { tee $BASE_DIR/clone-vm-$TIME.log >&3; }
exec >&${mytee[1]} 2>&1

# On any error delete TEMP_DIR
trap "rm -rf $TEMP_DIR; cd $BASE_DIR" EXIT

function help() {
    echo
    echo "Usage: ${0} [--option=argument] or ${0} [-o argument]"
    echo "  -h | --help help    display help"
    echo "  -a | --attach-disks Attach disks to a running VM, this is a separate functionality (Default: no)"
    echo "  -b | --base-vm      Name of base VM as displayed in 'virsh list'"
    echo "  -i | --base-ip      IPv4 address of base VM"
    echo "  -p | --prefix       Prefix of new VMs (1, 2, 3 ... will be appended to this prefix)"
    echo "  -x | --start-index  Starting index to be appended to PREFIX (Default: 1)"
    echo "  -n | --vms          Number of new VMs that should be created or if --attach-disks is "
    echo "                      provided VM name is constructed using --prefix and this option (Default: 1)"
    echo "  -d | --disks        Number of disks to be attached to each VM (Default: 0)"
    echo "  -s | --size         Size of each disk, should contain Unit as well (Default: 10G)"
    echo
    echo "NOTE:"
    echo "  Arguments for long options should be preceeded with '=' not space. Ex: --size=25G"
    echo "  Mandatory options for cloning & prepping VM: --base-vm, --prefix"
    echo "  Mandatory options for attaching disks to VM: --attach-disks, --prefix, --disks"
    echo "  Options --base-vm and --attach-disks are mutually exclusive"
    echo
    exit 1
}

function create_scripts() {

    # Script to be run on base vm before cloning (manual)
    cat << 'EOF' > startup.sh
#!/bin/bash

# Enable console access for every VM
systemctl enable serial-getty@ttyS0.service
systemctl start serial-getty@ttyS0.service

# Make interface comeup automatically
iface=$(basename $(ls /sys/class/net/$(ip addr | awk -F': ' '/state UP/ {print $2}' | grep ^e) -d))
sed -i 's/ONBOOT=no/ONBOOT=yes/' /etc/sysconfig/network-scripts/ifcfg-$iface

# virt-sysprep is still leaving some UUIDs
# Replace UUID of boot partition with actual disk name
disk=$(df /boot --output=source | tail -n 1)
cp -f /etc/fstab /etc/fstab.uuid
sed -r "/boot/ s|^UUID=[[:xdigit:]-]+|$disk|" /etc/fstab.uuid > /etc/fstab
EOF

    # Script to be run when VMs are booting for the first time (automatic)
    cat << 'EOF' > change_uuid.sh
#!/bin/bash

# Set a new UUID for network interface
iface=$(basename $(ls /sys/class/net/$(ip addr | awk -F': ' '/state UP/ {print $2}' | grep ^e) -d))
uuid=$(uuidgen $iface)
sed -ir "s/^UUID=.*/UUID=$uuid/" /etc/sysconfig/network-scripts/ifcfg-$iface

# Replace boot parition disk with UUID in fstab
disk=$(grep boot /etc/fstab | awk '{print $1}')
uuid=$(blkid $disk -o export | grep ^UUID)
cp -f /etc/fstab /etc/fstab.disk
sed -r "/boot/ s|$disk|$uuid|" /etc/fstab.disk > /etc/fstab
EOF

    chmod +x startup.sh change_uuid.sh

}

function compatibility_check() {

    # centos8 base on centos7 KVM conflicts with XFS file system forward compatibility
    host_ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
    guest_ver=$(virt-cat -d $BASE_VM /etc/system-release-cpe | awk -F':' '{print $5}')

    if (( $( echo "$host_ver < $guest_ver" | bc -l ) )); then
        cd $POOL_PATH
        if [ ! -d appliance ]; then
            curl -OL https://download.libguestfs.org/binaries/appliance/appliance-1.40.1.tar.xz
            tar xvfJ appliance-1.40.1.tar.xz
        fi
        LIBGUESTFS_PATH=$(pwd)/appliance/
        export LIBGUESTFS_PATH
        cd $TEMP_DIR
    fi

}

function perform_op() {

    # Options that needs to be enabled, preserve SSH related info
    ops=$(virt-sysprep --list-operations | grep -Pv 'ssh-userdir|ssh-hostkeys' | awk '{ printf "%s,", $1}' | sed 's/,$//')


    VMS=$((VMS+START_INDEX-1))
    vm_names=()
    for i in $(seq $START_INDEX $VMS)
    do
        name="${PREFIX}${i}"

        vm_names+=("$name")

        # Clone
        virt-clone --original "$BASE_VM" --name $name --auto-clone

        # Prep the clone
        # if `--selinux-relabel` is removed then `firshboot` script will not be trigerred
        virt-sysprep -d $name --selinux-relabel --enable $ops --firstboot ./change_uuid.sh

        # Start VM and attach disks
        virsh start $name

        # Create and attach disks
        if [[ $DISKS -ge 1 ]]
        then
            attach_disks_to_vm "$name"
        fi
    done

}

function create_vms() {

    echo "BEGIN"

    cd $TEMP_DIR

    # Creation of scripts to be run on base and new VMs
    create_scripts

    # Checks before proceeding with cloning
    compatibility_check

    # Clone and Sysprep VM
    perform_op

    cd $BASE_DIR

    echo "END"
}

function attach_disks_to_vm () {

    vm="$1"

    last_disk=$(virsh domblklist $vm | tail -2 | awk '{print $1}' | tr -d '\n')
    if echo $last_disk | grep ^s
    then
        dtype='sd'
    else
        dtype='vd'
    fi

    last_char=${last_disk:2}
    count=0
    for key in ${!CHAR_MAP[*]}
    do
        if [[ ${CHAR_MAP[$key]} -le ${CHAR_MAP[$last_char]} ]];
        then
            count=$((count+1))
            continue
        fi

        if [[ ${CHAR_MAP[$key]} -gt $((count+DISKS)) ]]
        then
            break
        fi

        qemu-img create -o preallocation=metadata -f qcow2 $POOL_PATH/"$vm-${CHAR_MAP[$key]}" $SIZE
        sleep .2
        virsh attach-disk $vm --source $POOL_PATH/"$vm-${CHAR_MAP[$key]}" --target "${dtype}${key}" --driver qemu --subdriver qcow2 --persistent
    done

}

function attach_disks() {

    echo "BEGIN"

    VMS=$((VMS+START_INDEX-1))
    for i in $(seq $START_INDEX $VMS)
    do
        name="${PREFIX}${i}"
        if ! virsh list --all | grep "$name"
        then
            echo Domain name "$name" is not found in 'virsh list --all'
        fi

        attach_disks_to_vm "$name"

    done

    echo "END"

}

function parse_args() {

    die() {
        # Complain to STDERR and show help
        echo "$*" >&2;
        help;
    }

    needs_arg() {
        # Handle no argument case for long option
        if [[ -z "$OPTARG"  ]]
        then
            die "No argument give for --${OPT} option"
        fi
    }

    while getopts :hb:i:p:n:d:s:g:-: OPT;
    do
        if [[ "$OPT" = "-" ]]           # long option supplied
        then
            OPT="${OPTARG%%=*}"
            OPTARG="${OPTARG#$OPT}"
            OPTARG="${OPTARG#=}"
        fi
        case "$OPT" in
            h | help            )   help;;
            a | attach-disks    )   needs_arg; ATTACH_DISKS=$OPTARG;;
            b | base-vm         )   needs_arg; BASE_VM=$OPTARG;;
            i | base-ip         )   needs_arg; BASE_IP=$OPTARG;;
            p | prefix          )   needs_arg; PREFIX=$OPTARG;;
            x | start-index     )   needs_arg; START_INDEX=$OPTARG;;
            n | vms             )   needs_arg; VMS=$OPTARG;;
            d | disks           )   needs_arg; DISKS=$OPTARG;;
            s | size            )   needs_arg; SIZE=$OPTARG;;
            :                   )   echo No arugment supplied for ${OPTARG} option; help;;
            ??*                 )   die Bad long option --$OPT; help;;
            ?                   )   die Bad short option -$OPTARG; help;;
        esac
    done


    if [[ "$BASE_VM" != "NULL" && "$ATTACH_DISKS" == "yes" ]]
    then
        echo "Options: --base-vm and --attach-disks shouldn't be provided at the same time"
        help
    fi

    if [[ "$BASE_VM" != "NULL" ]]
    then
        for value in "$BASE_VM" "$PREFIX"
        do
            if [[ "$value" == "NULL" ]]
            then
                echo "Mandatory options: --base-vm, --prefix"
                help
            fi
        done
    fi

    if [[ "$ATTACH_DISKS" == "yes" ]]
    then
        if [[ "$PREFIX" == "NULL" || "$DISKS" == 0 ]]
        then
            echo "Prefix should be supplied for attaching disks to VM starting with that prefix, along with number of disks"
            help
        fi
    fi

    if [[ $VMS -lt 1 || $DISKS -lt 0 || $START_INDEX -lt 1 ]]
    then
        echo "VMs should be >= 1, disks should be >= 0, index should be >= 1"
        help
    fi

    echo "Final arguments: ATTACH_DISKS: $ATTACH_DISKS; BASE_VM: $BASE_VM; BASE_IP: $BASE_IP; PREFIX: $PREFIX; START_INDEX: $START_INDEX; VMS: $VMS; DISKS: $DISKS; SIZE: $SIZE"

    if [[ "$ATTACH_DISKS" == "yes" ]]
    then
        attach_disks
    else
        create_vms
    fi

}

function main() {
    if [[ $# == 0 ]]
    then
        help
    else
        parse_args "$@"
    fi
}

main "$@"
