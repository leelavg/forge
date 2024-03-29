#!/bin/bash

# Pre-req:
# 1. Expects a SINGLE NODE OPENSHIFT created on AWS with only root disk
# 2. 'oc' pointing to sno cluster and 'aws' is configured to account used to create sno

# Formatting: shfmt -i 2 -ci -w <file>

# shellcheck disable=SC1083,SC2086,SC2155,SC2207
nodes=($(oc get no -o name | awk -F'/' {'print $2'}))
ns="topolvm-system"
oc="oc -n$ns "

# replace with name of your master node
master="master-0"

# 10GB disks are attached to the node
size=10

function create_attach_disks() {

  echo -- take note of master node instance id
  local ec2=$(
    aws ec2 describe-instances |
      jq -r '.Reservations[].Instances[]|.InstanceId+" "+(.Tags[] | select(.Key == "Name").Value)' |
      grep "$master" | awk '{print $1}'
  )

  local disks=4
  echo -- check for existing disks, we want $disks additional disks with size ${size}G
  local exist=$(
    aws ec2 describe-instances |
      jq -r --arg id "$ec2" '.Reservations[].Instances[]|select(.InstanceId==$id)|.BlockDeviceMappings | length'
  )

  # subtract root disk count
  exist=$((exist - 1))

  [[ $exist -ge $disks ]] && echo Instance already has $exist volumes attached && return

  local avail=$(aws ec2 describe-volumes | jq -r '.Volumes[].State' | grep -c available)
  local create=$((disks - avail - exist))
  echo -- create $create disks
  for _ in $(seq 1 $create); do
    aws ec2 create-volume --availability-zone ap-south-1a --size $size --volume-type standard
    sleep 2
  done

  echo -- wait for additional disks to be available
  local timeout=$(($(date +%s) + 60))
  while [[ $avail -lt $create ]]; do
    avail=$(aws ec2 describe-volumes | jq -r '.Volumes[].State' | grep -c available)
    [[ $timeout -lt $(date +%s) ]] && echo ----- EC2 volumes are not up && exit 1
    sleep 3
  done

  echo -- attach volumes to the instance: /dev/sd{c..f}
  local vols=($(aws ec2 describe-volumes | jq -r '.Volumes[] | select(.State=="available") | .VolumeId'))
  local ascii=($(printf '%b ' '\'{143..146}))
  for i in $(seq 0 $((disks - 1))); do
    aws ec2 attach-volume --volume-id "${vols[$i]}" --instance-id "$ec2" --device /dev/sd"${ascii[$i]}"
    sleep 3
  done

  echo -- verify volume attachment from aws cli
  exist=0
  timeout=$(($(date +%s) + 60))
  while [[ $exist -lt $disks ]]; do
    exist=$(
      aws ec2 describe-instances |
        jq -r --arg id "$ec2" '.Reservations[].Instances[]|select(.InstanceId==$id)|.BlockDeviceMappings | length'
    )
    [[ $timeout -lt $(date +%s) ]] && echo ----- Unable to attach volumes to EC2 instance && exit 1
    sleep 2
  done

}

function detach_delete_disks() {

  echo -- take note of master node instance id
  local ec2=$(
    aws ec2 describe-instances |
      jq -r '.Reservations[].Instances[]|.InstanceId+" "+(.Tags[] | select(.Key == "Name").Value)' |
      grep "$master" | awk '{print $1}'
  )

  echo -- take note of disks of size $size G attached to $ec2
  local vols=($(aws ec2 describe-volumes | jq -r --arg id "$ec2" '.Volumes[]|select(.Size==10)|.Attachments[]|select(.InstanceId==$id).VolumeId'))

  echo -- detach and delete volume
  for vol in "${vols[@]}"; do
    aws ec2 detach-volume --volume-id $vol --instance-id $ec2
    sleep 2
  done

  for vol in "${vols[@]}"; do
    aws ec2 delete-volume --volume-id $vol
  done
}

function operator() {
  # $1 = string, install/uninstall

  local pr_image="quay.io/rhn_support_lgangava/topolvm-operator:fcf105f"
  local main="alaudapublic/topolvm-operator:2.2.0"
  local commit="fcf105fe3acee052419310e2fee9e71d6f52d0bc"
  local repo="https://raw.githubusercontent.com/alauda/topolvm-operator/$commit/deploy/example"
  local operator="$(
    if ! [ -e /tmp/operator-top.yaml ]; then curl -sL $repo/operator-ocp.yaml -o /tmp/operator-top.yaml; fi
    sed -e "s,image:.*$,image: $pr_image,g" /tmp/operator-top.yaml
  )"

  if [[ "$1" == "install" ]]; then
    echo --- installing operator in $ns namespace
    echo "$operator" | oc apply -f -
    # Wait for namespace creation
    sleep 5
    $oc wait --for=condition=ready pod -l app=topolvm-operator --timeout=30s || {
      echo ----- Operator is not up && exit 1
    }
    $oc patch deployment topolvm-operator --patch "$(
      cat <<EOL
spec:
  template:
    spec:
      containers:
      - name: topolvm-operator
        imagePullPolicy: Always
EOL
    )"
    $oc wait --for=condition=ready pod -l app=topolvm-operator --timeout=30s || {
      echo ----- Operator is not up && exit 1
    }
  elif [[ "$1" == "uninstall" ]]; then
    echo "$operator" | oc delete -f -
  fi
}

function get_cr {
  # $1 = num, 1/2/3/4/5 (corresponding to the CR type, 1 & 2 go together)

  local result
  local image="quay.io/topolvm/topolvm-with-sidecar:0.10.2"
  local meta=$(
    cat <<EOL
---
apiVersion: topolvm.cybozu.com/v2
kind: TopolvmCluster
metadata:
  name: sample-cr
  namespace: $ns
spec:
  topolvmVersion: "$image"
  storage:
EOL
  )

  case $1 in

    1 | 2)
      # two device classes with same nodename but different devices
      result=$(
        cat <<EOL
$meta
    # two device classes with same nodename but different devices
    useAllNodes: false
    useAllDevices: false
    useLoop: false
    deviceClasses:
      - nodeName: "${nodes[0]}"
        classes:
          - volumeGroup: test-master
            className: hdd
            default: true
            devices: 
              - name: "/dev/${devices[0]}"
                type: "disk"
              - name: "/dev/${devices[1]}"
                type: "disk"
          - volumeGroup: test-master-1
            className: ssd
            devices: 
              - name: "/dev/${devices[2]}"
                type: "disk"
EOL
      )

      if [ $1 == 2 ]; then
        # add a disk to class 'ssd'
        result=$(
          cat <<EOL
$result
              # add device for expansion of volume group
              - name: "/dev/${devices[3]}"
                type: "disk"
EOL
        )
      fi
      ;;

    3)
      # single device class with nodename, devices at storage level
      result=$(
        cat <<EOL
$meta
    # single device class with nodename, devices at storage level
    useAllNodes: false
    useAllDevices: false
    useLoop: false
    devices: 
      - name: "/dev/${devices[0]}"
        type: "disk"
      - name: "/dev/${devices[1]}"
        type: "disk"
      - name: "/dev/${devices[2]}"
        type: "disk"
      - name: "/dev/${devices[3]}"
        type: "disk"
    deviceClasses:
      - nodeName: "${nodes[0]}"
        classes:
          - volumeGroup: test-master
            className: hdd
            default: true
EOL
      )
      ;;

    4)
      # all nodes and specific devices
      result=$(
        cat <<EOL
$meta
    # all nodes and specific devices
    useAllNodes: true
    useAllDevices: false
    useLoop: false
    devices: 
      - name: "/dev/${devices[0]}"
        type: "disk"
      - name: "/dev/${devices[1]}"
        type: "disk"
      - name: "/dev/${devices[2]}"
        type: "disk"
      - name: "/dev/${devices[3]}"
        type: "disk"
    volumeGroupName: test-master
    className: hdd
EOL
      )
      ;;

    5)
      # auto discovery of nodes and devices
      result=$(
        cat <<EOL
$meta
    # auto discovery of nodes and devices
    useAllNodes: true
    useAllDevices: true
    useLoop: true
    volumeGroupName: test-master
    className: hdd
EOL
      )
      ;;

    *)
      echo ----- Incorrect CR type requested && exit 1
      ;;

  esac

  echo "$result"
}

function get_sc() {
  # $1 = string, sc-imm-def/sc-imm-spec/sc-wffc-def (name of the StorageClass)

  local result
  case $1 in

    "sc-imm-def")
      # Immediate binding from default class
      result=$(
        cat <<EOL
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: sc-imm-def
provisioner: topolvm.cybozu.com
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOL
      )
      ;;

    "sc-imm-spec")
      # Immediate binding from specific class name
      result=$(
        cat <<EOL
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: sc-imm-spec
provisioner: topolvm.cybozu.com
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  "topolvm.cybozu.com/device-class": "ssd"
EOL
      )
      ;;
    "sc-wffc-def")
      # WaitForFirstConsumer binding from default class
      result=$(
        cat <<EOL
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: sc-wffc-def
provisioner: topolvm.cybozu.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOL
      )
      ;;

    *)
      echo ----- Incorrect StorageClass requested && exit 1
      ;;

  esac

  echo "$result"
}

function get_pvc() {
  # $1 = string, pvc name
  # $2 = string, volume mode
  # $3 = string, storage size in Gi
  # $4 = string, sc name

  local mode="ReadWriteOnce"
  # TODO: Should support RWOP?
  # [[ "$2" == "Block" ]] && mode="ReadWriteOncePod"
  local result=$(
    cat <<EOL
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $1
spec:
  accessModes:
    - $mode
  volumeMode: $2
  resources:
    requests:
      storage: $3
  storageClassName: $4
EOL
  )

  echo "$result"
}

function get_pod() {
  # $1 = string, pod name
  # $2 = string, Filesystem/Block
  # $3 = string, name of PVC

  local result=$(
    cat <<EOL
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $1
spec:
  replicas: 1
  selector:
    matchLabels:
      name: $1
  template:
    metadata:
      labels:
        name: $1
    spec:
      containers:
      - name: $1
        image: bash
        imagePullPolicy: IfNotPresent
EOL
  )

  if [[ "$2" == "Filesystem" ]]; then
    result=$(
      cat <<EOL
$result
        command: ["/usr/local/bin/bash","-c"]
        args: ["echo sample text > /mnt/pv/original && diff <(echo sample text) <(cat /mnt/pv/original) && echo all good && /usr/bin/tail -f /dev/null"]
        volumeMounts:
        - mountPath: /mnt/pv
          name: $3
EOL
    )

  elif [[ "$2" == "Block" ]]; then
    result=$(
      cat <<EOL
$result
        command: ["/usr/local/bin/bash","-c"]
        args: ["echo sample text > /tmp/original && dd if=/tmp/original of=/dev/xvda && dd if=/dev/xvda of=/tmp/copy bs=1 count=12 && cat /tmp/{original,copy} && diff <(cat /tmp/original) <(cat /tmp/copy) && echo all good && /usr/bin/tail -f /dev/null"]
        volumeDevices:
        - devicePath: /dev/xvda
          name: $3
EOL
    )
  fi

  result=$(
    cat <<EOL
$result
      volumes:
      - name: $3
        persistentVolumeClaim:
          claimName: $3
EOL
  )

  echo "$result"

}

function validate() {
  # $1 = string, CustomResource/PVC
  local timeout

  case $1 in
    "CustomResource")

      # $2 = string, name of volumegroup
      # $3 = num, number of expected disks in the volume group

      timeout=$(($(date +%s) + 30))
      while [[ \
        $($oc get deploy/topolvm-controller --ignore-not-found -o name | wc -l) -eq 0 || \
        $($oc get job -l 'app.kubernetes.io/name=prepare-volume-group' --ignore-not-found -o name | wc -l) -eq 0 || \
        $($oc get deploy -l 'app.kubernetes.io/name=topolvm-node' --ignore-not-found -o name | wc -l) -eq 0 ]]; do
        [[ $timeout -lt $(date +%s) ]] && echo ----- Resources are not created after deploying $1 && exit 1
        sleep 2
      done

      $oc wait --for=condition=available deploy/topolvm-controller --timeout=30s || {
        echo ----- Topolvm CSI Controller is not up && exit 1
      }
      $oc wait --for=condition=complete job -l 'app.kubernetes.io/name=prepare-volume-group' --timeout=30s || {
        echo ----- Preparing Volume Group failed && exit 1
      }
      $oc wait --for=condition=available deploy -l 'app.kubernetes.io/name=topolvm-node' --timeout=30s || {
        echo ----- Topolvm CSI Node is not up && exit 1
      }

      local cr_status=$($oc get topolvmclusters.topolvm.cybozu.com sample-cr -o json)

      timeout=$(($(date +%s) + 60))
      while [[ $(jq -r '.status.phase=="Ready"' <<<"$cr_status") != "true" ]]; do
        cr_status=$($oc get topolvmclusters.topolvm.cybozu.com sample-cr -o json)
        [[ $timeout -lt $(date +%s) ]] && echo ----- Topolvm Cluster CR phase is not in Ready state && exit 1
        sleep 2
      done

      [[ $($oc get cm -l topolvm/lvmdconfig=lvmdconfig -oname | wc -l) == 1 ]] || {
        echo ----- Unable to find lvmd config map && exit 1
      }

      local vg_count=$($oc debug node/${nodes[0]} -- chroot /host vgs $2 -opv_count --noheadings | awk '{print $1}')
      [[ "$3" != "$vg_count" ]] && echo ----- Expected $3 disks to be part of $2 volumegroup && exit 1

      ;;

    "PVC")
      # $2 = string, volume group from which the PVC is created
      # $3 = string, pvc size

      local pvc_name="sample-pvc"
      timeout=$(($(date +%s) + 30))
      if [[ $cr_type == 5 ]]; then
        while [[ $($oc describe pvc $pvc_name | grep -cP 'WaitForFirstConsumer|WaitForPodScheduled') == 0 ]]; do
          [[ $timeout -lt $(date +%s) ]] && echo ----- pvc/$pvc_name is not in condition WaitForFirstConsumer && exit 1
          sleep 2
        done
      fi

      local vg_name=$2
      while [[ $($oc get pvc $pvc_name -ojsonpath={'.status.phase'}) != "Bound" ]]; do
        [[ $timeout -lt $(date +%s) ]] && echo ----- pvc/$pvc_name is not in Bound phase && exit 1
        sleep 2
      done

      timeout=$(($(date +%s) + 30))
      local pv_name=$($oc get pvc sample-pvc -ojsonpath={'.spec.volumeName'})
      while [[ $($oc get pv $pv_name -ojsonpath={'.spec.capacity.storage'}) != "$3" ]]; do
        [[ $timeout -lt $(date +%s) ]] && echo ----- pv/$pv_name size is not matching spec size $3 && exit 1
        sleep 2
      done

      if [[ $cr_type == 5 ]]; then
        timeout=$(($(date +%s) + 120))
        while [[ $($oc get pvc $pvc_name -ojsonpath={'.status.capacity.storage'}) != "$3" ]]; do
          [[ $timeout -lt $(date +%s) ]] && echo ----- pvc/$pvc_name storage is not match "$3" && exit 1
          sleep 2
        done
      fi

      [[ $($oc get logicalvolumes.topolvm.cybozu.com $pv_name -ojsonpath={'.status.currentSize'}) != "$3" ]] && echo ----- logicalvolumes/$pv_name size is not matching spec $3 && exit 1
      local lv_pv=$($oc get logicalvolumes.topolvm.cybozu.com $pv_name -ojsonpath={'.status.volumeID'})
      local lv_node=$($oc debug node/${nodes[0]} -- chroot /host lvs $vg_name -olv_name --noheadings | awk '{print $1}')
      [[ "$lv_pv" != "$lv_node" ]] && echo ----- pv/$pv_name is not from volume group $vg_name && exit 1

      ;;

    *)
      echo ----- Incorrect resource supplied to be validated && exit 1
      ;;

  esac

}

function deploy() {
  # $1 = string, install/uninstall
  # $2 = string, CustomResource/StorageClass/PVC
  # $3 = string, content of yaml manifest
  if [ "$1" == "install" ]; then
    echo "$3" | oc apply -f - || {
      echo ---- Unable to install $2 manifest && exit 1
    }
  elif [ "$1" == "uninstall" ]; then
    case "$2" in
      "CustomResource")

        local vgs=$($oc get topolvmclusters.topolvm.cybozu.com sample-cr -ojsonpath={'.status.nodeStorageState[*].successClasses[*].vgName'})
        echo "$3" | oc delete -f - || {
          echo ---- Unable to uninstall $2 manifest && exit 1
        }
        local filter="vg_name=${vgs// /||vg_name=}"
        local disks=($($oc debug node/${nodes[0]} -- chroot /host pvs -opv_name -S $filter --noheadings | awk '{print $1}'))
        $oc debug node/${nodes[0]} -- chroot /host vgremove -S "$filter"
        $oc debug node/${nodes[0]} -- chroot /host pvremove ${disks[*]}
        local out=$($oc debug node/${nodes[0]} -- chroot /host vgs -ovg_name --noheadings)
        [[ -n "$out" ]] && echo ----- Unable to delete volumegroup and physical volumes && exit 1
        ;;

      "StorageClass")
        echo "$3" | oc delete -f - || {
          echo ---- Unable to uninstall $2 manifest && exit 1
        }
        ;;

      "PVC")
        echo "$3" | oc delete --force -f - || {
          echo ---- Unable to uninstall $2 manifest && exit 1
        }
        [[ $($oc get logicalvolumes.topolvm.cybozu.com --ignore-not-found | wc -l) != 0 ]] && echo ----- Unable to delete underlying logical volume after deleting PVC/PV && exit 1
        ;;

      *)
        echo ----- Unsupported resource $1 supplied to be deleted && exit 1
        ;;

    esac
  fi

}

function test_resource() {
  # $1 = string, CustomResource/StorageClass/PVC
  local manifest
  case $1 in
    "CustomResource")
      # $2 = string, install/uninstall
      manifest="$(get_cr $cr_type)"
      deploy $2 $1 "$manifest"

      [[ $2 == "uninstall" ]] && return 0

      if [[ $cr_type == 1 ]]; then
        validate $1 "test-master" 2
        validate $1 "test-master-1" 1
      elif [[ $cr_type == 2 ]]; then
        validate $1 "test-master" 2
        validate $1 "test-master-1" 2
      else
        validate $1 "test-master" 4
      fi
      ;;

    "StorageClass")
      # $2 = string, install/uninstall
      manifest="$(get_sc $sc_name)"
      deploy $2 $1 "$manifest"
      [[ $2 == "uninstall" ]] && return 0
      ;;

    "PVC")
      # $2 = string, install/uninstall
      # $3 = string, Filesystem/Block
      # $4 = string, size

      manifest="$(get_pvc "sample-pvc" $3 $4 $sc_name)"

      if [[ $cr_type == 5 ]]; then
        if [[ $2 == "uninstall" || $($oc get deploy/sample-pod --ignore-not-found | wc -l) == 0 && $2 == "install" ]]; then
          local temp="$(get_pod "sample-pod" $3 "sample-pvc")"
          manifest=$(
            cat <<EOL
$manifest
$temp
EOL
          )
        fi
      fi

      deploy $2 $1 "$manifest"
      [[ $2 == "uninstall" ]] && return 0

      local vg_name
      case "$sc_name" in
        "sc-imm-spec")
          vg_name="test-master-1"
          ;;
        "sc-imm-def" | "sc-wffc-def")
          vg_name="test-master"
          ;;
        *)
          echo ----- Unsupported resource $sc_name supplied to validate $1
          ;;
      esac

      validate $1 $vg_name $4

      ;;

    *)
      echo ----- Unsupported resource $1 supplied to be validated && exit 1
      ;;
  esac

}

function start_test() {
  # Create a CustomResource and perform testing corresponding to that CR

  local disks=4
  devices=($(oc debug node/${nodes[0]} -- lsblk -no Name,Size | grep "$size"G | awk '{print $1}'))
  [[ ${#devices[*]} -lt $disks ]] && echo ----- Not able to confirm disks availability in master node && exit 1

  cr_type=1

  echo --- CR$cr_type-install
  test_resource "CustomResource" "install"

  sc_name="sc-imm-def"

  echo --- CR$cr_type-$sc_name-install
  test_resource "StorageClass" "install"

  echo --- CR$cr_type-$sc_name-PVC-FS-install
  test_resource "PVC" "install" "Filesystem" "1Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-expand
  test_resource "PVC" "install" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-uninstall
  test_resource "PVC" "uninstall" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-uninstall
  test_resource "StorageClass" "uninstall"

  sc_name="sc-imm-spec"

  echo --- CR$cr_type-$sc_name-install
  test_resource "StorageClass" "install"

  echo --- CR$cr_type-$sc_name-PVC-Block-install
  test_resource "PVC" "install" "Block" "1Gi"

  cr_type=2

  echo --- CR$cr_type-install
  test_resource "CustomResource" "install"

  echo --- CR$cr_type-$sc_name-PVC-Block-expand
  test_resource "PVC" "install" "Block" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-Block-uninstall
  test_resource "PVC" "uninstall" "Block" "2Gi"

  echo --- CR$cr_type-$sc_name-uninstall
  test_resource "StorageClass" "uninstall"

  echo --- CR$cr_type-uninstall
  test_resource "CustomResource" "uninstall"

  # Type3 not supported https://github.com/alauda/topolvm-operator/issues/73
  # ------
  # cr_type=3

  # echo --- CR$cr_type-install
  # test_resource "CustomResource" "install"

  # sc_name="sc-imm-def"

  # echo --- CR$cr_type-$sc_name-install
  # test_resource "StorageClass" "install"

  # echo --- CR$cr_type-$sc_name-PVC-Block-install
  # test_resource "PVC" "install" "Block" "1Gi"

  # echo --- CR$cr_type-$sc_name-PVC-Block-expand
  # test_resource "PVC" "install" "Block" "2Gi"

  # echo --- CR$cr_type-$sc_name-PVC-Block-uninstall

  # echo --- CR$cr_type-$sc_name-uninstall
  # test_resource "StorageClass" "uninstall"

  # echo --- CR$cr_type-uninstall
  # test_resource "CustomResource" "uninstall"
  # ------

  cr_type=4

  echo --- CR$cr_type-install
  test_resource "CustomResource" "install"

  sc_name="sc-imm-def"

  echo --- CR$cr_type-$sc_name-install
  test_resource "StorageClass" "install"

  echo --- CR$cr_type-$sc_name-PVC-FS-install
  test_resource "PVC" "install" "Filesystem" "1Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-expand
  test_resource "PVC" "install" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-uninstall
  test_resource "PVC" "uninstall" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-uninstall
  test_resource "StorageClass" "uninstall"

  echo --- CR$cr_type-uninstall
  test_resource "CustomResource" "uninstall"

  cr_type=5

  echo --- CR$cr_type-install
  test_resource "CustomResource" "install"

  sc_name="sc-wffc-def"

  echo --- CR$cr_type-$sc_name-install
  test_resource "StorageClass" "install"

  echo --- CR$cr_type-$sc_name-PVC-FS-install
  test_resource "PVC" "install" "Filesystem" "1Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-expand
  test_resource "PVC" "install" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-FS-uninstall
  test_resource "PVC" "uninstall" "Filesystem" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-Block-install
  test_resource "PVC" "install" "Block" "1Gi"

  echo --- CR$cr_type-$sc_name-PVC-Block-expand
  test_resource "PVC" "install" "Block" "2Gi"

  echo --- CR$cr_type-$sc_name-PVC-Block-uninstall
  test_resource "PVC" "uninstall" "Block" "2Gi"

  echo --- CR$cr_type-$sc_name-uninstall
  test_resource "StorageClass" "uninstall"

  echo --- CR$cr_type-uninstall
  test_resource "CustomResource" "uninstall"
}

function main() {

  # Step 1: Attach 4 disks of 10GB size if doesn't exist
  create_attach_disks

  # Step 2: Install operator and validate
  operator 'install'

  # Step 3: Start testing various combinations
  start_test

  # Step 4: Uninstall operator
  operator 'uninstall'

  # Step 5: Detach disks (optional)
  detach_delete_disks

}

main
