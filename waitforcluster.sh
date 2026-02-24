#!/usr/bin/env bash

# Waits for the Kubernetes cluster to become fully operational before proceeding
# with kubectl/helm commands. Three phases: API server health, node registration,
# node readiness. Surfaces crash diagnostics early instead of waiting for timeouts.

set -e

ALL_NODES=(control0 control1 control2 worker0 worker1 worker2)
CONTROL_NODES=(control0 control1 control2)

# --- Phase 1: API server health ---
echo "==> Phase 1/3: Waiting for API server to become healthy (timeout: 120s)..."
deadline=$((SECONDS + 120))
while true; do
  if kubectl get --raw /healthz &>/dev/null; then
    echo "    API server is healthy."
    break
  fi
  if [[ $SECONDS -ge $deadline ]]; then
    echo "ERROR: API server did not become healthy within 120s." >&2
    echo "Collecting diagnostics from control plane nodes..." >&2
    for node in "${CONTROL_NODES[@]}"; do
      echo "--- $node: kube-apiserver ---" >&2
      ssh ubuntu@"$node" "sudo systemctl status kube-apiserver 2>&1 || true; sudo journalctl -u kube-apiserver -n 50 --no-pager 2>&1 || true" >&2
      echo "--- $node: etcd ---" >&2
      ssh ubuntu@"$node" "sudo systemctl status etcd 2>&1 || true; sudo journalctl -u etcd -n 50 --no-pager 2>&1 || true" >&2
    done
    exit 1
  fi
  # Early crash detection: if apiserver is failed on all control nodes, bail immediately
  all_failed=true
  for node in "${CONTROL_NODES[@]}"; do
    if ! ssh ubuntu@"$node" "sudo systemctl is-failed kube-apiserver" &>/dev/null; then
      all_failed=false
      break
    fi
  done
  if $all_failed; then
    echo "ERROR: kube-apiserver is in failed state on all control nodes." >&2
    for node in "${CONTROL_NODES[@]}"; do
      echo "--- $node: kube-apiserver ---" >&2
      ssh ubuntu@"$node" "sudo journalctl -u kube-apiserver -n 50 --no-pager 2>&1 || true" >&2
    done
    exit 1
  fi
  echo "    API server not ready yet, retrying in 5s..."
  sleep 5
done

# --- Phase 2: Node registration ---
echo "==> Phase 2/3: Waiting for all nodes to register (timeout: 180s)..."
deadline=$((SECONDS + 180))
last_crash_check=0
while true; do
  registered=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  missing=()
  for node in "${ALL_NODES[@]}"; do
    if ! echo "$registered" | grep -qw "$node"; then
      missing+=("$node")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "    All 6 nodes registered."
    break
  fi
  if [[ $SECONDS -ge $deadline ]]; then
    echo "ERROR: Not all nodes registered within 180s. Missing: ${missing[*]}" >&2
    for node in "${missing[@]}"; do
      echo "--- $node: kubelet ---" >&2
      ssh ubuntu@"$node" "sudo journalctl -u kubelet -n 50 --no-pager 2>&1 || true" >&2
    done
    exit 1
  fi
  # Every 30s, check if kubelet has crashed on missing nodes
  if [[ $((SECONDS - last_crash_check)) -ge 30 ]]; then
    last_crash_check=$SECONDS
    for node in "${missing[@]}"; do
      if ssh ubuntu@"$node" "sudo systemctl is-failed kubelet" &>/dev/null; then
        echo "ERROR: kubelet has crashed on $node." >&2
        echo "--- $node: kubelet ---" >&2
        ssh ubuntu@"$node" "sudo journalctl -u kubelet -n 50 --no-pager 2>&1 || true" >&2
        exit 1
      fi
    done
  fi
  echo "    Waiting for nodes: ${missing[*]} (retrying in 5s)..."
  sleep 5
done

# --- Phase 3: Node readiness ---
echo "==> Phase 3/3: Waiting for all nodes to become Ready (timeout: 120s)..."
deadline=$((SECONDS + 120))
while true; do
  not_ready=()
  for node in "${ALL_NODES[@]}"; do
    status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$status" != "True" ]]; then
      not_ready+=("$node")
    fi
  done
  if [[ ${#not_ready[@]} -eq 0 ]]; then
    echo "    All 6 nodes are Ready."
    break
  fi
  if [[ $SECONDS -ge $deadline ]]; then
    echo "ERROR: Not all nodes became Ready within 120s. Not ready: ${not_ready[*]}" >&2
    for node in "${not_ready[@]}"; do
      echo "--- $node: kubectl describe ---" >&2
      kubectl describe node "$node" 2>&1 | tail -30 >&2
      echo "--- $node: kubelet ---" >&2
      ssh ubuntu@"$node" "sudo journalctl -u kubelet -n 50 --no-pager 2>&1 || true" >&2
    done
    exit 1
  fi
  echo "    Waiting for nodes to be Ready: ${not_ready[*]} (retrying in 5s)..."
  sleep 5
done

echo "==> Cluster is ready. Proceeding with configuration."
