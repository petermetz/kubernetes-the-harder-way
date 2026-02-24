#!/usr/bin/env bash

# The master script that performs full setup of the entire cluster, starting from absolute zero.
# It is run on the host machine and aggregates all other scripts.

set -xe
dir=$(dirname "$0")
source "$dir/variables.sh"
source "$dir/helpers.sh"
sudo -v

export USE_CILIUM
export HOMEBREW_NO_AUTO_UPDATE=1

case $(uname -s) in
  Darwin)
    brew install \
      qemu wget curl cdrtools dnsmasq tmux cfssl kubernetes-cli helm
    ;;

  Linux)
    sudo "$dir/addaptrepos.sh"
    sudo apt install -y \
      qemu-system-x86 curl genisoimage dnsmasq tmux golang-cfssl nfs-kernel-server kubectl helm
    ;;
esac

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

cd "$dir/auth"
./genauth.sh
./genenckey.sh
./setuplocalkubeconfig.sh
cd ..

ubuntu_img_url="https://cloud-images.ubuntu.com/plucky/current/plucky-server-cloudimg-${arch}.img"
dest="$dir/ubuntu-cloud.img"

# 1. Get the remote file size in bytes
remote_size=$(curl -sI "$ubuntu_img_url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r')

# 2. Check if local file exists and matches the size
if [ -f "$dest" ] && [ "$(stat -c%s "$dest")" -eq "$remote_size" ]; then
    echo "File already exists and size matches ($remote_size bytes). Skipping download."
else
    echo "==> File missing or size mismatch. Downloading Ubuntu cloud image..."
    wget_retry -O "$dest" "$ubuntu_img_url" || {
      echo "ERROR: Failed to download Ubuntu cloud image. Aborting." >&2
      exit 1
    }
fi

"$dir/vmsetupall.sh"
sudo -E "$dir/setuphost.sh"
sudo "$dir/vmlaunchall.sh" kubenet-qemu

for vmid in $(seq 0 6); do
  "$dir/vmsshsetup.sh" $vmid
done

"$dir/deploysetup.sh"
"$dir/auth/deployauth.sh"
"$dir/deploybinaries.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo ./setupcontrol.sh" &
  pids+=($!)
done
wait ${pids[@]}

ssh ubuntu@gateway "sudo ./setupgateway.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
for i in $(seq 0 2); do
  ssh ubuntu@worker$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
wait ${pids[@]}

if [[ -z $USE_CILIUM ]]; then
  sudo "$dir/setuproutes.sh"
fi

"$dir/waitforcluster.sh"

"$dir/setupkubeletaccess.sh"
"$dir/addhelmrepos.sh"
"$dir/setupcluster.sh"

echo "Your Kubernetes cluster is now fully functional!"
