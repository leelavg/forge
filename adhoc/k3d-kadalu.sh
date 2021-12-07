#!/bin/bash
# DONOT RUN WITHOUT CHECKING THE SCRIPT

only='busybox'
options="mhp:a:t:k:f:"
prg="teardown"
pull="no"
agents=3
kadalu="no"

# Similar to https://github.com/RedHatQE/pylero/blob/master/gen_docs.sh script
usage() {
  echo
  echo "Create a k3d cluster and optionally deploy kadalu"
  echo
  echo "Usage: ./k3d-kadalu.sh [options]"
  echo "options:"
  echo "  p   Create a cluster without pulling latest images. (default: no)"
  echo "  a   Number of k3d agents (default: 3)"
  echo "  t   Program type: setup/teardown(default)"
  echo "  k   Deploy Kadalu Operator (default: no)"
  echo "  m   Create a minimal k3d-kadalu cluster (p: no, a:0, t: setup, k: no)"
  echo "      can be overriden like: -m -a 2 -k no"
  echo "  f   Filter to be used for importing docker images"
  echo "  h   Print this help."
  echo
}

while getopts $options opt; do
  case ${opt} in
    m)
      prg="setup"
      pull="no"
      agents=0
      ;;
    p)
      pull=$OPTARG
      ;;
    a)
      agents=$OPTARG
      ;;
    t)
      prg=$OPTARG
      ;;
    k)
      kadalu=$OPTARG
      ;;
    f)
      only=$OPTARG
      ;;
    h)
      usage
      exit
      ;;
    :)
      printf "\nInvalid option: $OPTARG requires an argument\n" 1>&2
      usage 1>&2
      exit
      ;;
    \?)
      printf "\nInvalid Option: -$OPTARG\n" 1>&2
      usage 1>&2
      exit
      ;;
  esac
done

shift $((OPTIND - 1))
echo Received Arguments: pull="$pull" agents="$agents" prg="$prg" kadalu="$kadalu" only="$only"
echo

if [[ $prg == "setup" ]]; then

  version=$(curl -s https://update.k3s.io/v1-release/channels | jq -r '.data[]|select(.id=="latest")|.latest')
  version=${version/+/-}

  if ! [[ "$(docker images | grep 'leelavg/k3s')" =~ "$version" ]]; then
    echo "\
FROM rancher/k3s:$version as k3s
FROM alpine:3
RUN apk add --no-cache util-linux udev lvm2 gptfdisk sgdisk
COPY --from=k3s / /
RUN mkdir -p /etc && \
    echo 'hosts: files dns' > /etc/nsswitch.conf && \
    echo "PRETTY_NAME=\"K3s ${version}\"" > /etc/os-release && \
    chmod 1777 /tmp
VOLUME /var/lib/kubelet
VOLUME /var/lib/rancher/k3s
VOLUME /var/lib/cni
VOLUME /var/log
ENV CRI_CONFIG_FILE="/var/lib/rancher/k3s/agent/etc/crictl.yaml"
ENV PATH="\$PATH:/bin/aux"
ENTRYPOINT "/bin/k3s"
CMD "agent"
" | docker build - -t leelavg/k3s:$version
  fi

  # Start local docker registry if it doesn't exist
  if ! docker ps --format {{.Names}} | grep registry; then
    docker container run -d --name registry.localhost --restart always -p 5000:5000 registry:2
  fi

  # Update local docker images
  if [ $pull == "yes" ]; then
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -P "'$only'" | xargs -I image docker pull image
  fi

  docker rmi $(docker images -f "dangling=true" -q) && docker volume rm $(docker volume ls -qf dangling=true)

  if [[ $pull == "yes" || ! -e /tmp/allinone.tar ]]; then
    docker save $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -P $only) -o /tmp/allinone.tar
  fi

  # Create registries.yaml for k3d
  # Setup k3d
  cat >~/.k3d/registries.yaml <<EOF
mirrors:
  "registry.localhost:5000":
    endpoint:
      - "http://registry.localhost:5000"
EOF

  # Cleanup and mount disks
  # dev={c,d,e,f,g,h,i,j,k,l,m,n,o,p,q}
  # if eval wipefs /dev/sd$dev | grep -e "sd\w"; then
  #   echo "[DANGER] File system signatures found on some of "$(eval echo /dev/sd$dev) devices", proceed with wipefs on them?"
  #   select yn in "Yes" "No"; do
  #     case $yn in
  #       Yes)
  #         for i in $(eval echo $dev); do
  #           wipefs -a -f /dev/sd$i
  #         done
  #         break
  #         ;;
  #       No)
  #         echo "Proceeding without wiping devices may face issues while using them in k3d cluster"
  #         break
  #         ;;
  #     esac
  #   done
  # fi

  # Pods need a shared mount
  mkdir -p /tmp/k3d/kubelet/pods

  # Create k3d test cluster
  if [[ $agents -eq 0 ]]; then
    k3d cluster create test -a $agents \
      -v /tmp/k3d/kubelet/pods:/var/lib/kubelet/pods:shared \
      -v /dev/sdb:/dev/sdb@server:0 -v /dev/sdc:/dev/sdc@server:0 -v /dev/sdd:/dev/sdd@server:0 -v /dev/sde:/dev/sde@server:0 -v /dev/sdf:/dev/sdf@server:0 \
      -v /dev/sdg:/dev/sdg@server:0 -v /dev/sdh:/dev/sdh@server:0 -v /dev/sdi:/dev/sdi@server:0 -v /dev/sdj:/dev/sdj@server:0 -v /dev/sdk:/dev/sdk@server:0 \
      -v /dev/sdl:/dev/sdl@server:0 -v /dev/sdn:/dev/sdn@server:0 -v /dev/sdo:/dev/sdo@server:0 -v /dev/sdp:/dev/sdp@server:0 -v /dev/sdq:/dev/sdq@server:0 \
      -v ~/.k3d/registries.yaml:/etc/rancher/k3s/registries.yaml \
      --k3s-arg "--kube-apiserver-arg=feature-gates=EphemeralContainers=true@server:*" \
      --k3s-arg "--disable=local-storage@server:*" \
      --image "leelavg/k3s:$version" || exit 1
  elif [[ $agents -eq 3 ]]; then
    k3d cluster create test -a $agents \
      -v /tmp/k3d/kubelet/pods:/var/lib/kubelet/pods:shared \
      -v /dev/sdb:/dev/sdb@agent:0 -v /dev/sdc:/dev/sdc@agent:0 -v /dev/sdd:/dev/sdd@agent:0 -v /dev/sde:/dev/sde@agent:0 -v /dev/sdf:/dev/sdf@agent:0 \
      -v /dev/sdg:/dev/sdg@agent:1 -v /dev/sdh:/dev/sdh@agent:1 -v /dev/sdi:/dev/sdi@agent:1 -v /dev/sdj:/dev/sdj@agent:1 -v /dev/sdk:/dev/sdk@agent:1 \
      -v /dev/sdl:/dev/sdl@agent:2 -v /dev/sdn:/dev/sdn@agent:2 -v /dev/sdo:/dev/sdo@agent:2 -v /dev/sdp:/dev/sdp@agent:2 -v /dev/sdq:/dev/sdq@agent:2 \
      -v ~/.k3d/registries.yaml:/etc/rancher/k3s/registries.yaml \
      --k3s-arg "--kube-apiserver-arg=feature-gates=EphemeralContainers=true@server:*" \
      --k3s-arg "--disable=local-storage@server:*" \
      --image "leelavg/k3s:$version" || exit 1
  fi

  # Import all the docker images into k3d cluster
  k3d image import -t -k /tmp/allinone.tar -c test

  # Attach registry network to k3d
  docker network connect k3d-test registry.localhost

  # Remove taints from the node
  for name in $(kubectl get nodes -o jsonpath={'..name'}); do kubectl taint nodes $name node.cloudprovider.kubernetes.io/uninitialized-; done

  if [ $kadalu == "yes" ]; then
    # Set 'verbose' to 'yes'
    curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/manifests/kadalu-operator.yaml | sed 's/"no"/"yes"/' | kubectl apply -f -
    curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/manifests/csi-nodeplugin.yaml | sed 's/"no"/"yes"/' | kubectl apply -f -
  fi

fi

if [[ $prg == "teardown" ]]; then

  kubectx k3d-test || exit 1

  # Pull all images that are currently deployed before teardown
  if [ $pull == "yes" ]; then
    for i in $(kubectl get pods --namespace kadalu -o jsonpath="{..image}" |
      grep -P $only); do docker pull "$i"; done
  fi

  # Remove Kadalu
  if [[ $(kubectl get ns kadalu --ignore-not-found | wc -l) != 0 ]]; then
    # Remove sanity pods if there are any
    kubectl delete ds -l name=sanity-ds --force -n kadalu
    kubectl delete deploy -l name=sanity-dp --force -n kadalu
    bash <(curl -s https://raw.githubusercontent.com/kadalu/kadalu/devel/extras/scripts/cleanup)
  fi

  # Delete k3d cluster
  k3d cluster delete test

  # Unmount any left overs of k3d
  sleep 2
  diff <(df -ha | grep pods | awk '{print $NF}') <(df -h | grep pods | awk '{print $NF}') | awk '{print $2}' | xargs umount -l

  # Remove any left overs of docker
  docker rmi $(docker images -f "dangling=true" -q)
  docker volume prune -f
  docker volume rm $(docker volume ls -qf dangling=true)
fi
