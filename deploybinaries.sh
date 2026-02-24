#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

source "$dir/variables.sh"
source "$dir/helpers.sh"

# Networking safety: Timeout after 30s if the connection drops
SCP_OPTS="-o ConnectTimeout=30 -o BatchMode=yes"

etcd_archive=etcd-v${etcd_version}-linux-${arch}.tar.gz
crictl_archive=crictl-v${cri_version}-linux-${arch}.tar.gz
containerd_archive=containerd-${containerd_version}-linux-${arch}.tar.gz
cni_plugins_archive=cni-plugins-linux-${arch}-v${cni_plugins_version}.tgz

mkdir -p "$dir/bin"

echo "==> Downloading core components to $dir/bin..."
wget_retry -P "$dir/bin" \
  "https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/$etcd_archive" \
  "https://dl.k8s.io/release/v${k8s_version}/bin/linux/${arch}/kube-apiserver" \
  "https://dl.k8s.io/release/v${k8s_version}/bin/linux/${arch}/kube-controller-manager" \
  "https://dl.k8s.io/release/v${k8s_version}/bin/linux/${arch}/kube-scheduler" \
  "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${cri_version}/${crictl_archive}" \
  "https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.${arch}" \
  "https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_archive}" \
  "https://dl.k8s.io/release/v${k8s_version}/bin/linux/${arch}/kubelet" || {
    echo "ERROR: Failed to download one or more core binaries after retries. Aborting." >&2
    exit 1
  }

if [[ -z $USE_CILIUM ]]; then
  echo "==> Downloading CNI and kube-proxy components..."
  wget_retry -P "$dir/bin" \
    "https://github.com/containernetworking/plugins/releases/download/v${cni_plugins_version}/${cni_plugins_archive}" \
    "https://dl.k8s.io/release/v${k8s_version}/bin/linux/${arch}/kube-proxy" || {
      echo "ERROR: Failed to download CNI/kube-proxy binaries after retries. Aborting." >&2
      exit 1
    }
fi

for i in $(seq 0 2); do
  echo "Deploying to control$i..."
  
  # Added a simple retry loop for network stability
  retry_count=0
  until scp $SCP_OPTS \
    "$dir/bin/$etcd_archive" \
    "$dir/bin/kube-apiserver" \
    "$dir/bin/kube-controller-manager" \
    "$dir/bin/kube-scheduler" \
    "$dir/bin/$crictl_archive" \
    "$dir/bin/runc.$arch" \
    "$dir/bin/$containerd_archive" \
    "$dir/bin/kubelet" \
    ubuntu@control$i:; do
      
      retry_count=$((retry_count + 1))
      if [ $retry_count -ge 3 ]; then
        echo "ERROR: Failed to scp to control$i after 3 attempts." >&2
        exit 1
      fi
      echo "SCP failed on control$i, retrying in 5 seconds..."
      sleep 5
  done

  if [[ -z $USE_CILIUM ]]; then
    scp $SCP_OPTS "$dir/bin/$cni_plugins_archive" "$dir/bin/kube-proxy" ubuntu@control$i:
  fi
done

for i in $(seq 0 2); do
  echo "Deploying to worker$i..."
  
  # Retry loop for core worker binaries
  retry_count=0
  until scp $SCP_OPTS \
    "$dir/bin/$crictl_archive" \
    "$dir/bin/runc.$arch" \
    "$dir/bin/$containerd_archive" \
    "$dir/bin/kubelet" \
    ubuntu@worker$i:; do
      
      retry_count=$((retry_count + 1))
      if [ $retry_count -ge 3 ]; then
        echo "ERROR: Failed to scp to worker$i after 3 attempts." >&2
        exit 1
      fi
      echo "SCP failed on worker$i, retrying in 5 seconds (Attempt $retry_count/3)..."
      sleep 5
  done

  # Conditional CNI/Proxy deployment with its own retry logic
  if [[ -z $USE_CILIUM ]]; then
    echo "Deploying CNI and Proxy to worker$i..."
    retry_cni=0
    until scp $SCP_OPTS \
      "$dir/bin/$cni_plugins_archive" \
      "$dir/bin/kube-proxy" \
      ubuntu@worker$i:; do
        
        retry_cni=$((retry_cni + 1))
        if [ $retry_cni -ge 3 ]; then
          echo "ERROR: Failed to scp CNI/Proxy to worker$i after 3 attempts." >&2
          exit 1
        fi
        echo "SCP (CNI) failed on worker$i, retrying in 5 seconds..."
        sleep 5
    done
  fi
done