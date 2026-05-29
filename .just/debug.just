set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talosconfig := source_directory() + '/../secrets/talosconfig'
kubeconfig  := source_directory() + '/../secrets/kubeconfig'

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
