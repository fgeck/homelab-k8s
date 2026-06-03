set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()
talosconfig   := source_directory() + '/../secrets/talosconfig'
kubeconfig    := source_directory() + '/../secrets/kubeconfig'
age_key       := env('HOME') + '/.age/key.txt'

[private]
default:
    just bootstrap -l

# ─── VALIDATION ───────────────────────────────────────────────────────────────

# Check all nodes are reachable via talosctl and report their version + stage
check-nodes:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f "{{talosconfig}}" ]] || { echo "ERROR: run: just talos gen-talosconfig"; exit 1; }
    rc=0
    for node in nas k8s-01 k8s-02; do
        ip=$(just talos _ip "$node")
        if out=$(talosctl --talosconfig="{{talosconfig}}" -n "$ip" version --short 2>&1); then
            stage=$(talosctl --talosconfig="{{talosconfig}}" -n "$ip" get machinestatus -o yaml 2>/dev/null | yq '.spec.stage' || echo "unknown")
            echo "OK   $node ($ip) — stage: $stage"
        else
            echo "FAIL $node ($ip) — $out" >&2; rc=1
        fi
    done
    exit $rc

# Check etcd health on all controlplane nodes
check-etcd:
    [[ -f "{{talosconfig}}" ]] || { echo "ERROR: run: just talos gen-talosconfig"; exit 1; }
    talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip nas)" etcd members
    talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip nas)" etcd status

# Check Kubernetes nodes are Ready
check-k8s:
    [[ -f "{{kubeconfig}}" ]] || { echo "ERROR: run: just talos get-kubeconfig"; exit 1; }
    KUBECONFIG={{kubeconfig}} kubectl get nodes -o wide
    KUBECONFIG={{kubeconfig}} kubectl get pods -n kube-system -o wide

# Run all pre-bootstrap checks
check-all: check-nodes check-etcd check-k8s

# ─── BOOTSTRAP ────────────────────────────────────────────────────────────────

# Full bootstrap: namespaces → sops secret → Cilium + CoreDNS → Flux
all: _namespaces _sops-secret _cilium-coredns flux

# Apply namespace manifests
[private]
_namespaces:
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/namespaces.yaml"

# Render and apply the sops-age secret (age key injected at runtime)
[private]
_sops-secret:
    minijinja-cli --autoescape=none "{{bootstrap_dir}}/resources.yaml.j2" \
        -D "agekey=$(grep -v '^#' '{{age_key}}' | base64 | tr -d '\n')" \
        | KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f -

# Install Cilium + CoreDNS via helmfile (CoreDNS depends on Cilium)
[private]
_cilium-coredns:
    helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.yaml" sync

# Bootstrap Flux from GitHub (run after Cilium is up)
flux:
    KUBECONFIG={{kubeconfig}} flux bootstrap git \
        --url=ssh://git@github.com/fgeck/homelab-k8s.git \
        --branch=main \
        --path=clusters/homelab-k8s \
        --private-key-file="$HOME/.ssh/fluxGithubReadKeyK8s" \
        --components-extra=image-reflector-controller,image-automation-controller
