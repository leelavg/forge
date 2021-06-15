#!/bin/bash

# ===== STANDALONE SCRIPT ===== NO NEED TO CLONE WHOLE REPO =====

# Current Status:
# Total Steps: create_scripts, prep_kvm, prep_base, compatibility_check, perform_op and write_ips
# Untested Steps [TODO]: prep_base and write_ips

# Sample usage:
# bash clone-vm.sh --base-vm=centos7-34 --base-ip=10.10.10.10 --prefix=7-34 --vms=3
# For help run: bash clone-vm.sh -h

# BEGIN - Existing base image
# END - Create VMs from base image, attach disks (optional) and write IPs to a file (optional)

# Required RPMs on KVM :
# yum install virt-install libvirt libvirt-python libvirt-client libguestfs libguestfs-tools net-tools

# Scope:
# - Clone a base VM (either ISO or PXE booted), attach disks
# - Thin base image results in faster cloning and prepping the clones
# - Minimum expectation from the script is:
#   - A matching base VM name as supplied in the arguments with no disks attached
#   - Shutdown the base VM after installing/tuning required (like copying SSH keys) settings
#   - Run the script with necessary arguments as stated in `Usage:`
#
# Cases covered in addition to cloning VM and attaching disks:
# - Force re-label SELinux labels
# - Support for cloning CentOS 8 base VM on CentOS 7 KVM (similar for RHEL)
# - Custom scripts on replacing correct UUIDs of disks and network interfaces
# - No deletion of VMs is happening and KVM by defaults prohibits overwrites of domain
#
# Known limitations:
# - Only core functionality (clone VM, attach disks) is implemented
# - Experimental: take note of VMs IP, currently dumps ip address from arp cache
# - Checking for available space isn't implemented
# - No error recovery is inbuilt (just backoff if something goes wrong)

# Notes:
# pool_path=$(virsh pool-dumpxml default | grep -Po '(?<=path>).*?(?=<)')
# for i in `virsh list --all | grep -vP 'centos|Name|leela|--' | awk '{print $2}'`; do virsh destroy $i; virsh undefine $i; rm -f $pool_path/$i*; done;


# Break on any failure
set -e
set -o pipefail

BASE_VM=NULL
BASE_IP=NULL
PREFIX=NULL
VMS=NULL
DISKS=0
SIZE="10G"
GET_IP="no"
TEMP_DIR=$(mktemp -d)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "  -b | --base-vm      Name of base VM as displayed"
    echo "  -i | --base-ip      IPv4 address of base VM"
    echo "  -p | --prefix       Prefix of new VMs (1, 2, 3 ... will be appended to this prefix)"
    echo "  -n | --vms          Number of new VMs that should be created, should be greater than 0"
    echo "  -d | --disks        Number of disks to be attached to each VM (Default: 0)"
    echo "  -s | --size         Size of each disk, should contain Unit as well (Default: 10G)"
    echo "  -g | --get-ip       EXPERIMENTAL, writes IPs of new VMs to a file (Default: no)"
    echo "  Arguments for long options should be preceeded with '=' not space. Ex: --size=25G"
    echo "  Apart from --disks, --size, --get-ip all other options are mandatory."
    echo
    exit 1
}

function create_scripts() {

    # Script to be run on base vm before cloning (automatic)
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
disk=$(df /boot --output=source | tail -n 1)
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

    chmod +x startup.sh change_uuid.sh

}

function prep_kvm() {

    # Generate a SSH keypair if one doesn't exist
    echo n | ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa

}

function prep_base() {

    # Shutdown base vm
    if ! virsh list --inactive | grep $BASE_VM
    then
        virsh shutdown $BASE_VM
    fi

    # Wait for base vm to go down
    count=$(($(date +%s) + 30))
    while [[ "$(date +%s)" -lt $count ]]
    do
        ret=$(timeout 5 ping -c 5 $BASE_IP; echo $?)
        if [[ $ret -ne 0 ]]
        then
            break
        fi
    done

    # Check if base vm was already prepped before
    ret=$(virt-cat -d $BASE_VM /etc/fstab.uuid >/dev/null 2>&1 && echo 0 || echo 1)
    if [[ $ret -eq 0 ]]
    then
        # VM is already prepped no need for all the extra work
        return 0
    fi

    # Need to copy and run startup.sh in the base VM
    virt-copy-out -d $BASE_VM /root/.ssh/authorized_keys .

    # Add KVM SSH Key
    cat ~/.ssh/id_rsa.pub >> authorized_keys

    # Copy appended key into base vm
    virt-copy-in -d $BASE_VM authorized_keys /root/.ssh/authorized_keys

    # Copy startup.sh into base vm
    virt-copy-in -d $BASE_VM startup.sh /root/startup.sh

    # Start base vm
    virsh start $BASE_VM

    # Wait for base vm to come online
    count=$(($(date +%s) + 60))
    while [[ "$(date +%s)" -lt $count ]]
    do
        ret=$(timeout 5 ping -c 5 $BASE_IP; echo $?)
        if [[ $ret -eq 0 && $ret -ne 124 ]]
        then
            break
        fi
    done

    # Run startup.sh on base vm
    ssh -o "StrictHostKeyChecking no" root@$BASE_IP "bash /root/startup.sh"

    # Shutdown VM
    virsh shutdown $BASE_VM

    # Wait for base vm to go down
    count=$(($(date +%s) + 30))
    while [[ "$(date +%s)" -lt $count ]]
    do
        ret=$(timeout 5 ping -c 5 $BASE_IP; echo $?)
        if [[ $ret -ne 0 ]]
        then
            break
        fi
    done

}

function compatibility_check() {

    # centos8 base on centos7 KVM conflicts with XFS file system forward compatibility
    host_ver=$(awk -F':' '{print $5}' /etc/system-release-cpe)
    guest_ver=$(virt-cat -d $BASE_VM /etc/system-release-cpe | awk -F':' '{print $5}')

    # Pool path, (if not using default pool, it should be changed in below regex accordingly)
    pool_path=$(virsh pool-dumpxml default | grep -Po '(?<=path>).*?(?=<)')
    if [[ $host_ver -lt $guest_ver ]]; then
        cd $pool_path
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

    if virsh domblklist $BASE_VM | tail -2 | awk '{print $1}' | tr -d '\n' | grep ^s
    then
        dtype='sd'
    else
        dtype='vd'
    fi

    declare -A dict
    counter=1

    # Disk mapping, assuming no disks are attached to base VM
    for i in {b..z}
    do
        dict["$counter"]=$i
        counter=$((counter + 1))
    done

    vm_names=()
    for i in $(seq 1 $VMS)
    do
        vm_names+=("${PREFIX}${i}")
    done

    for name in "${vm_names[@]}"
    do
        # Clone
        virt-clone --original $BASE_VM --name $name --auto-clone

        # Prep the clone
        # if `--selinux-relabel` is removed then `firshboot` script will not be trigerred
        virt-sysprep -d $name --selinux-relabel --enable $ops --firstboot ./change_uuid.sh

        # Set VM autostart
        virsh autostart $name

        # Start VM and attach disks
        virsh start $name

        # Create and attach disks
        if [[ $DISKS -ge 1 ]]
        then
            for i in $(seq 1 $DISKS)
            do
                qemu-img create -o preallocation=metadata -f qcow2 $pool_path/"$name-$i" $SIZE
                sleep .2
                virsh attach-disk $name --source $pool_path/"$name-$i" --target "${dtype}${dict[$i]}" --driver qemu --subdriver qcow2 --persistent
            done
        fi
    done

}

function write_ips() {

    # Try to get newly created vm ips from arp cache

    # Clean ARP Cache
    ip -s -s neigh flush all

    # Wait for arp cache (for ~2min) to have entries =~ number of newly created VMs
    count=$(($(date +%s) + 120))
    while [[ "$(date +s)" -lt $count ]]
    do
        ret=$(arp -e | grep -c ^dhcp)
        if [[ $ret -ge $VMS ]]
        then
            break
        fi
    done

    # Let's try to get maximum number of IPs even if arp cache isn't as expected
    ips=($(arp -e | grep ^dhcp | awk '{print $1}'))

    declare -A domain_mac

    for name in "${vm_names[@]}"
    do
        # This'll be of eth mac address but not of bridge's
        mac=$(virsh dumpxml $name | grep 'mac address' | awk -F\' '{print $2}')
        domain_mac["$name"]="$mac"
    done

    filter=()
    for key in "${!ips[@]}"
    do
        # Try connecting to all the dhcp entries
        host=${ips[$key]/\.lab.*/}
        out=$(timeout 3 ssh -o "StrictHostKeyChecking no" -q root@$host exit && echo SUCCESS || echo FAIL)
        if [[ $out == "SUCCESS" ]]
        then
            filter+=("$host")
        fi
    done

    declare -A ip_mac
    for host in "${filter[@]}"
    do
        mac=$(ssh -o "StrictHostKeyChecking no" -q root@$host bash << 'EOF'
cat /sys/class/net/$(ip addr | awk -F': ' '/state UP/ {print $2}' | grep ^e)/address
EOF
)
        ip_mac["$mac"]="$host"
    done

    # Finally get IPs corresponding to Domain names
    echo "# Below are the list of IPs found from arp cache" > "ip-$TIME.log"
    for key in "${!domain_mac[@]}"
    do
        value=${domain_mac[$key]}
        if [ -v ip_mac["$value"] ]
        then
            echo "${ip_mac[$value]} $key" >> "ip-$TIME.log"
        else
            echo "Unable to find IP for '$key'" >> "ip-$TIME.log"
        fi
    done
}


function create_vms() {

    echo "BEGIN"

    cd $TEMP_DIR

    # Creation of scripts to be run on base and new VMs
    create_scripts

    # Operations on KVM hypervisor
    prep_kvm

    # Operation on base vm
    prep_base

    # Checks before proceeding with cloning
    compatibility_check

    # Clone and Sysprep VM
    perform_op

    cd $BASE_DIR

    if [[ $GET_IP == "yes" ]]
    then
        # EXPERIMENTAL: Get newly created VM IPs
        write_ips
    fi

    echo "END"
}

function parse_args() {

    die() {
        # Complain to STDERR and show help
        echo "$*" >&2;
        help;
    }

    needs_args() {
        # Handle no argument case for long option
        if [[ -z "$OPTARG"  ]]
        then
            die "No argument give for --${OPT} option"
        fi
    }

    while getops :hb:i:p:n:d:s:-: OPT;
    do
        if [[ "$OPT" = "-" ]]           # long option supplied
        then
            OPT="${OPTARG%%=*}"
            OPTARG="${OPTARG#$OPT}"
            OPTARG="${OPTARG#=}"
        fi
        case "$OPT" in
            h | help    )   help;;
            b | base-vm )   needs_arg; BASE_VM=$OPTARG;;
            i | base-ip )   needs_arg; BASE_IP=$OPTARG;;
            p | prefix  )   needs_arg; PREFIX=$OPTARG;;
            n | vms     )   needs_arg; VMS=$OPTARG;;
            d | disks   )   needs_arg; DISKS=$OPTARG;;
            s | size    )   needs_arg; SIZE=$OPTARG;;
            g | get-ip  )   needs_arg; GET_IP=$OPTARG;;
            :           )   echo No arugment supplied for ${OPTARG} option; help;;
            ??*         )   die Bad long option --$OPT; help;;
            ?           )   die Bad short option -$OPTARG; help;;
        esac
    done

    for value in "$BASE_VM" "$BASE_IP" "$PREFIX" "$VMS"
    do
        if [[ "$value" == "NULL" ]]
        then
            echo "Only --disks, --size, --get-ip options are optional."
            help
        fi
    done

    if [[ $VMS -lt 1 || $DISKS -lt 0 ]]
    then
        echo "VMs should be > 1 and disks should be >= 0"
        help
    fi

    create_vms

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
