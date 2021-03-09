#!/bin/bash
# DONOT RUN WITHOUT CHECKING THE SCRIPT

if [[ $1 == 'setup' ]]; then
  # Start local docker registry if it doesn't exist
  if docker ps --format {{.Names}} | grep -v registry; then 
    docker container run -d --name registry.localhost --restart always -p 5000:5000 registry:2
  fi

  # Update local docker images
  negate='test-|registry|alpine|k3|local|<none>'
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -Pv $negate | xargs -I image docker pull image
  docker rmi $(docker images -f "dangling=true" -q) && docker volume rm $(docker volume ls -qf dangling=true)
  docker save $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -Pv $negate) -o /tmp/allinone.tar

  # Create registries.yaml for k3d
  # Setup k3d
  cat > ~/.k3d/registries.yaml << EOF
mirrors:
  "registry.localhost:5000":
    endpoint:
      - "http://registry.localhost:5000"
EOF

  # Cleanup and mount disks
  for i in {c,d,e}; do
    wipefs -a /dev/sd$i; mkfs.xfs /dev/sd$i;
    mkdir -p /mnt/sd$i; mount /dev/sd$i /mnt/sd$i;
  done;
  # Pods need a shared mount
  mkdir -p /tmp/k3d/kubelet/pods

  # Create k3d test cluster
  k3d cluster create test -a 3 -v /tmp/k3d/kubelet/pods:/var/lib/kubelet/pods:shared -v /mnt/sdc:/mnt/sdc -v /mnt/sdd:/mnt/sdd -v /mnt/sde:/mnt/sde -v ~/.k3d/registries.yaml:/etc/rancher/k3s/registries.yaml

  # Import all the docker images into k3d cluster
  k3d image import -k /tmp/allinone.tar -c test

  # Attach registry network to k3d
  docker network connect k3d-test registry.localhost

  # Remove taints from the node
  for name in $(kubectl get nodes -o jsonpath={'..name'}); do kubectl taint nodes $name node.cloudprovider.kubernetes.io/uninitialized-; done;

  # Set 'verbose' to 'yes'
  curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/manifests/kadalu-operator.yaml | sed 's/"no"/"yes"/' | kubectl apply -f -
fi

if [[ $1 == 'teardown' ]]; then

  # Pull all images that are currently deployed before teardown
  negate='test-|registry|alpine|k3|local|<none>'
  for i in $(kubectl get pods --namespace kadalu -o jsonpath="{..image}" | grep -Pv $negate); do docker pull "$i"; done;

  # Remove Kadalu
  bash <(curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/extras/scripts/cleanup)

  # Delete k3d cluster
  k3d cluster delete test

  # Unmount any left overs of k3d
  diff <(df -ha | grep pods | awk '{print $NF}') <(df -h | grep pods | awk '{print $NF}') | awk '{print $2}' | xargs umount -l

  # Cleanup mount point
  for i in {c,d,e}; do rm -rf /mnt/sd$i/*; umount -l /mnt/sd$i; done;

  # Remove any left overs of docker
  docker rmi $(docker images -f "dangling=true" -q)
  docker volume prune -f
  docker volume rm $(docker volume ls -qf dangling=true)
fi
