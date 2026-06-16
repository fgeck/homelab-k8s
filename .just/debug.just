set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talosconfig      := source_directory() + '/../secrets/talosconfig'
kubeconfig       := source_directory() + '/../secrets/kubeconfig'
nfs_csi_test_dir := source_directory() + '/../clusters/building-blocks/base/apps/nfs-csi-test/app'
test_storage_dir := source_directory() + '/test-storage'

[private]
default:
    just debug -l

# ─── NODE STATUS ─────────────────────────────────────────────────────────────

# Show machine stage + ready status for all nodes
status:
    #!/usr/bin/env bash
    set -euo pipefail
    for node in nas k8s-01 k8s-02; do
        ip=$(just talos _ip "$node")
        echo -n "$node ($ip): "
        talosctl --talosconfig="{{talosconfig}}" get machinestatus \
            --nodes "$ip" --endpoints "$ip" 2>&1 | awk 'NR==2 {print $6, "ready="$7}' || echo "unreachable"
    done

# Show all service states for a node. Usage: just debug services nas
services node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" service --nodes "$ip" --endpoints "$ip"

# Show network addresses (IPs) on a node. Usage: just debug addresses nas
addresses node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" get addresses --nodes "$ip" --endpoints "$ip"

# Show network link names on a node — useful when interface name is unknown. Usage: just debug links nas
links node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" get links --nodes "$ip" --endpoints "$ip"

# ─── LOGS ────────────────────────────────────────────────────────────────────

# Tail dmesg (Talos system log) for a node. Usage: just debug dmesg nas
dmesg node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" dmesg --nodes "$ip" --endpoints "$ip" --tail

# Follow dmesg live for a node. Usage: just debug dmesg-follow nas
dmesg-follow node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" dmesg --nodes "$ip" --endpoints "$ip" --follow

# Tail logs for a specific service. Usage: just debug logs nas etcd
logs node service:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" logs --nodes "$ip" --endpoints "$ip" "{{service}}"

# Follow logs for a specific service. Usage: just debug logs-follow k8s-01 kubelet
logs-follow node service:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" logs --nodes "$ip" --endpoints "$ip" --follow "{{service}}"

# ─── ETCD ────────────────────────────────────────────────────────────────────

# Show etcd member list
etcd-members:
    talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip nas)" etcd members

# Show etcd status (leader, db size, etc.) across all nodes
etcd-status:
    #!/usr/bin/env bash
    for node in nas k8s-01 k8s-02; do
        ip=$(just talos _ip "$node")
        echo "=== $node ==="
        talosctl --talosconfig="{{talosconfig}}" -n "$ip" etcd status
    done

# ─── KUBERNETES ──────────────────────────────────────────────────────────────

# Show node status and IPs
nodes:
    KUBECONFIG={{kubeconfig}} kubectl get nodes -o wide

# Show all pods across all namespaces
pods:
    KUBECONFIG={{kubeconfig}} kubectl get pods -A -o wide

# Describe a node. Usage: just debug describe-node nas
describe-node node:
    KUBECONFIG={{kubeconfig}} kubectl describe node "{{node}}"

# ─── STORAGE ─────────────────────────────────────────────────────────────────

# Show Talos mount status for a node. Usage: just debug mounts k8s-01
mounts node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" get mountstatus --nodes "$ip" --endpoints "$ip"

# Show Talos volume status for a node. Usage: just debug volumes k8s-01
volumes node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" get volumestatus --nodes "$ip" --endpoints "$ip"

# Show discovered volumes for a node. Usage: just debug discovered-volumes k8s-01
discovered-volumes node:
    #!/usr/bin/env bash
    ip=$(just talos _ip "{{node}}")
    talosctl --talosconfig="{{talosconfig}}" get discoveredvolumes --nodes "$ip" --endpoints "$ip"

# Test PV/PVC provisioning: creates a PVC + pod, writes a file, reads it back, then cleans up
test-storage:
    #!/usr/bin/env bash
    set -euo pipefail
    ns="debug-storage-$$"
    trap 'echo "Cleaning up..."; KUBECONFIG={{kubeconfig}} kubectl delete namespace "$ns" --ignore-not-found --wait=false' EXIT

    KUBECONFIG={{kubeconfig}} kubectl create namespace "$ns"
    KUBECONFIG={{kubeconfig}} kubectl apply -n "$ns" -f "{{test_storage_dir}}/pvc.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply -n "$ns" -f "{{test_storage_dir}}/pod.yaml"

    echo "Waiting for PVC to bind..."
    KUBECONFIG={{kubeconfig}} kubectl wait -n "$ns" pvc/test-pvc \
        --for=jsonpath='{.status.phase}'=Bound --timeout=60s

    echo "Waiting for pod to complete..."
    KUBECONFIG={{kubeconfig}} kubectl wait -n "$ns" pod/test-pod \
        --for=condition=Ready=false --timeout=60s || true
    KUBECONFIG={{kubeconfig}} kubectl wait -n "$ns" pod/test-pod \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s

    echo "Pod output:"
    KUBECONFIG={{kubeconfig}} kubectl logs -n "$ns" test-pod
    echo "PV/PVC provisioning: OK"

# Test NFS media share rw: creates test ns + static PV/PVC + pod, streams probe output, then cleans up
test-nfs:
    #!/usr/bin/env bash
    set -euo pipefail
    trap '
        echo "Cleaning up..."
        KUBECONFIG={{kubeconfig}} kubectl delete namespace test --ignore-not-found --wait=false
        KUBECONFIG={{kubeconfig}} kubectl delete pv pv-nfs-media --ignore-not-found --wait=false
    ' EXIT

    KUBECONFIG={{kubeconfig}} kubectl create namespace test --dry-run=client -o yaml \
        | KUBECONFIG={{kubeconfig}} kubectl apply -f -
    KUBECONFIG={{kubeconfig}} kubectl apply -f "{{nfs_csi_test_dir}}/persistentvolume.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply -n test -f "{{nfs_csi_test_dir}}/persistentvolumeclaim.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply -n test -f "{{nfs_csi_test_dir}}/pod.yaml"

    echo "Waiting for PVC to bind..."
    KUBECONFIG={{kubeconfig}} kubectl wait -n test pvc/pvc-nfs-media \
        --for=jsonpath='{.status.phase}'=Bound --timeout=60s

    echo "Waiting for pod to be ready..."
    KUBECONFIG={{kubeconfig}} kubectl wait -n test pod/nfs-media-rw-check \
        --for=condition=Ready --timeout=120s

    echo "Pod output:"
    KUBECONFIG={{kubeconfig}} kubectl logs -n test nfs-media-rw-check
    echo "NFS rw probe: OK"
