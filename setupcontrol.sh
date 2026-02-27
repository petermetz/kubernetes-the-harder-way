#!/usr/bin/env bash

# This script installs Kubernetes control plane components on a node.

set -xe
dir=$(dirname "$0")
source "$dir/variables.sh"
source "$dir/helpers.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

vmaddr=$(ip addr show | grep -Po 'inet \K192\.168\.42\.1\d+')
vmname=$(hostname -s)

# etcd

etcd_archive=etcd-v${etcd_version}-linux-${arch}.tar.gz

# Verify etcd archive was pre-deployed by deploybinaries.sh
if [[ -f "$etcd_archive" ]]; then
  echo "==> Found pre-deployed etcd archive: $(pwd)/$etcd_archive"
else
  echo "ERROR: etcd archive not found at $(pwd)/$etcd_archive" >&2
  echo "  This file should have been deployed by deploybinaries.sh." >&2
  echo "  Please ensure deploybinaries.sh ran successfully before this script." >&2
  exit 1
fi

tar -xvf "$etcd_archive"

# PREVENT "Text file busy": Remove existing binaries before copying for reentrancy
rm -f /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/etcdutl
cp etcd-v${etcd_version}-linux-${arch}/etcd* /usr/local/bin/

mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd/
cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

cat <<EOF | tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
TimeoutStartSec=180
ExecStart=/usr/local/bin/etcd \\
  --name $vmname \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${vmaddr}:2380 \\
  --listen-peer-urls https://${vmaddr}:2380 \\
  --listen-client-urls https://${vmaddr}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${vmaddr}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster control0=https://192.168.42.11:2380,control1=https://192.168.42.12:2380,control2=https://192.168.42.13:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable etcd
systemctl start etcd

# Wait for all 3 etcd members to be healthy before proceeding.
# systemctl start etcd (Type=notify) blocks until this node's etcd is ready,
# which requires quorum (2/3). But we wait for ALL 3 members so that
# kube-apiserver won't log connection errors for a lagging third member.
echo "==> Waiting for etcd cluster to become fully healthy (3/3 members)..."
etcd_tls="--cacert=/etc/etcd/ca.pem --cert=/etc/etcd/kubernetes.pem --key=/etc/etcd/kubernetes-key.pem"
etcd_endpoints="--endpoints=https://192.168.42.11:2379,https://192.168.42.12:2379,https://192.168.42.13:2379"
deadline=$((SECONDS + 120))
while true; do
  started_count=$(etcdctl $etcd_tls member list 2>/dev/null | grep -c ", started," || true)
  if [[ "$started_count" -eq 3 ]]; then
    echo "    etcd cluster is healthy (3/3 members started)."
    break
  fi
  if [[ $SECONDS -ge $deadline ]]; then
    echo "ERROR: etcd cluster did not reach 3/3 healthy members within 120s." >&2
    echo "  Members found started: $started_count/3" >&2
    etcdctl $etcd_tls $etcd_endpoints endpoint status --write-out=table 2>&1 >&2 || true
    etcdctl $etcd_tls member list 2>&1 >&2 || true
    exit 1
  fi
  echo "    etcd members started: $started_count/3, retrying in 3s..."
  sleep 3
done

# --- Kubernetes Control Plane Section ---

mkdir -p /etc/kubernetes/config

# Verify K8s control plane binaries were pre-deployed by deploybinaries.sh
k8s_binaries=(kube-apiserver kube-controller-manager kube-scheduler)
missing_binaries=()
for bin in "${k8s_binaries[@]}"; do
  if [[ -f "$bin" ]]; then
    echo "==> Found pre-deployed binary: $(pwd)/$bin"
  else
    missing_binaries+=("$bin")
  fi
done
if [[ ${#missing_binaries[@]} -gt 0 ]]; then
  echo "ERROR: The following K8s control plane binaries were not found in $(pwd)/:" >&2
  for bin in "${missing_binaries[@]}"; do
    echo "  - $bin" >&2
  done
  echo "  These files should have been deployed by deploybinaries.sh." >&2
  echo "  Please ensure deploybinaries.sh ran successfully before this script." >&2
  exit 1
fi

chmod +x kube-apiserver kube-controller-manager kube-scheduler

# PREVENT "Text file busy": Unlink old binaries
rm -f /usr/local/bin/kube-apiserver /usr/local/bin/kube-controller-manager /usr/local/bin/kube-scheduler
cp kube-apiserver kube-controller-manager kube-scheduler /usr/local/bin/

mkdir -p /var/lib/kubernetes/
cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
  service-account-key.pem service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/

# kube-apiserver

cat <<EOF | tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${vmaddr} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://192.168.42.11:2379,https://192.168.42.12:2379,https://192.168.42.13:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://192.168.42.21:6443 \\
  --service-cluster-ip-range=10.32.0.0/16 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# kube-controller-manager

cp kube-controller-manager.kubeconfig /var/lib/kubernetes/

cat <<EOF | tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.0.0.0/8 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/16 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# kube-scheduler

cp kube-scheduler.kubeconfig /var/lib/kubernetes/

cat <<EOF | tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

cat <<EOF | tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler
