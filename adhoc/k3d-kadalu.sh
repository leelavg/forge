#!/bin/bash
# DONOT RUN WITHOUT CHECKING THE SCRIPT

negate='test-|registry|alpine|k3|local|<none>|act-|moby|binfmt'
only='operator|server|csi'
options="mhp:a:t:k:"
prg="teardown"
pull="yes"
agents=3
kadalu="yes"

# Similar to https://github.com/RedHatQE/pylero/blob/master/gen_docs.sh script
usage()
{
    echo
    echo "Create a k3d cluster and optionally deploy kadalu"
    echo
    echo "Usage: ./k3d-kadalu.sh [options]"
    echo "options:"
    echo "  p   Create a cluster without pulling latest (kadalu) images. (default: yes)"
    echo "  a   Number of k3d agents (default: 3)"
    echo "  t   Program type: setup/teardown(default)"
    echo "  k   Deploy Kadalu Operator (default: yes)"
    echo "  m   Create a minimal k3d-kadalu cluster (p: no, a:1, t: setup, k: yes)"
    echo "      can be overriden like: -m -a 2 -k no"
    echo "  h   Print this help."
    echo
}

while getopts $options opt; do
    case ${opt} in
        m )
            prg="setup"
            pull="no"
            agents=1
            ;;
        p )
            pull=$OPTARG
            ;;
        a )
            agents=$OPTARG
            ;;
        t )
            prg=$OPTARG
            ;;
        k )
            kadalu=$OPTARG
            ;;
        h )
            usage
            exit;;
        : )
            printf "\nInvalid option: $OPTARG requires an argument\n" 1>&2
            usage 1>&2
            exit;;
        \? )
            printf "\nInvalid Option: -$OPTARG\n" 1>&2
            usage 1>&2
            exit;;
    esac
done

shift $((OPTIND -1))
echo Received Arguments: pull="$pull" agents="$agents" prg="$prg" kadalu="$kadalu"
echo

if [[ $prg == "setup" ]]; then

    # Start local docker registry if it doesn't exist
    if ! docker ps --format {{.Names}} | grep registry; then
        docker container run -d --name registry.localhost --restart always -p 5000:5000 registry:2
    fi

  # Update local docker images
  if [ $pull == "yes" ]; then
      docker images --format '{{.Repository}}:{{.Tag}}' | grep -P $only | xargs -I image docker pull image
  fi

  docker rmi $(docker images -f "dangling=true" -q) && docker volume rm $(docker volume ls -qf dangling=true)

  if [[ $pull == "yes" || ! -e /tmp/allinone.tar ]]; then
      docker save $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -P $only) -o /tmp/allinone.tar
  fi

  # Create registries.yaml for k3d
  # Setup k3d
  cat > ~/.k3d/registries.yaml << EOF
mirrors:
  "registry.localhost:5000":
    endpoint:
      - "http://registry.localhost:5000"
EOF

  # Cleanup and mount disks
  dev={c,d,e}
  if eval wipefs /dev/sd$dev | grep -e "sd\w" ; then
      echo "[DANGER] File system signatures found on some of "$(eval echo /dev/sd$dev) devices", proceed with wipefs on them?"
      select yn in "Yes" "No"; do
          case $yn in
              Yes )
                  for i in $(eval echo $dev); do
                      wipefs -a -f /dev/sd$i;
                  done;
                  break ;;
              No ) echo "Proceeding without wiping devices may face issues while using them in k3d cluster for kadalu"; break;;
          esac
      done
  fi

  # Pods need a shared mount
  mkdir -p /tmp/k3d/kubelet/pods

  # Create k3d test cluster
  k3d cluster create test -a $agents \
      -v /tmp/k3d/kubelet/pods:/var/lib/kubelet/pods:shared \
      -v /dev/sdc:/dev/sdc -v /dev/sdd:/dev/sdd \
      -v /dev/sde:/dev/sde \
      -v ~/.k3d/registries.yaml:/etc/rancher/k3s/registries.yaml \
      --k3s-server-arg "--kube-apiserver-arg=feature-gates=EphemeralContainers=true" \
      --k3s-server-arg --disable=local-storage

  # Import all the docker images into k3d cluster
  k3d image import -t -k /tmp/allinone.tar -c test

  # Attach registry network to k3d
  docker network connect k3d-test registry.localhost

  # Remove taints from the node
  for name in $(kubectl get nodes -o jsonpath={'..name'}); do kubectl taint nodes $name node.cloudprovider.kubernetes.io/uninitialized-; done

  if [ $kadalu == "yes" ]; then
      # Set 'verbose' to 'yes'
      curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/manifests/kadalu-operator.yaml | sed 's/"no"/"yes"/' | kubectl apply -f -
  fi

fi

if [[ $prg == "teardown" ]]; then

  kubectx k3d-test || exit 1

  # Remove sanity pods if there are any
  kubectl delete ds -l name=sanity-ds --wait=true
  kubectl delete deploy -l name=sanity-dp --wait=true

  # Pull all images that are currently deployed before teardown
  if [ $pull == "yes" ]; then
      for i in $(kubectl get pods --namespace kadalu -o jsonpath="{..image}" \
          | grep -P $only); do docker pull "$i"; done;
  fi

  # Remove Kadalu
  bash <(curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/extras/scripts/cleanup)

  # Delete k3d cluster
  k3d cluster delete test

  # Unmount any left overs of k3d
  diff <(df -ha | grep pods | awk '{print $NF}') <(df -h | grep pods | awk '{print $NF}') | awk '{print $2}' | xargs umount -l

  # Cleanup mount point
  # for i in {c,d,e}; do rm -rf /mnt/sd$i/*; umount -l /mnt/sd$i; done;

  # Remove any left overs of docker
  docker rmi $(docker images -f "dangling=true" -q)
  docker volume prune -f
  docker volume rm $(docker volume ls -qf dangling=true)
fi
