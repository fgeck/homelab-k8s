#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod talos     'talos/mod.just'
mod bootstrap 'bootstrap/mod.just'
mod sops      '.just/sops.just'
mod debug     '.just/debug.just'

age_key      := env('HOME') + '/.age/key.txt'
talos_dir    := justfile_dir() + '/talos'
talos_secrets := talos_dir + '/talos-secrets.sops.yaml'
kubeconfig   := justfile_dir() + '/secrets/kubeconfig'
flux_key     := env('HOME') + '/.ssh/fluxGithubReadKeyK8s'

[private]
default:
    just -l

# ─── PREREQUISITES ────────────────────────────────────────────────────────────

# Verify all required tools are installed
check-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=0
    for tool in talosctl minijinja-cli sops yq flux kubectl helmfile age gum; do
        if ! which "$tool" &>/dev/null; then
            echo "MISSING: $tool"
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] && echo "All tools present."
    exit $missing

# ─── FULL SETUP GUIDE ─────────────────────────────────────────────────────────

# Print the full setup guide step by step
setup:
    #!/usr/bin/env bash
    cat <<'EOF'
    ══════════════════════════════════════════════════════
      homelab-k8s — Talos + Flux full setup guide
    ══════════════════════════════════════════════════════

    Step 1  Get schematic ID:
              just talos schematic-id
            → paste result into talos/values.yaml (schematicId)

    Step 2  Get ISO URL and download it for Proxmox:
              just talos installer-url

    Step 3  Create 3 Proxmox VMs, boot from ISO.
            Wait until each node shows "maintenance" on console.

    Step 4  Generate cluster secrets:
              just talos gen-secrets

    Step 5  Apply configs to all nodes (first-time, insecure):
              just talos apply-node nas    <ip> --insecure
              just talos apply-node k8s-01 <ip> --insecure
              just talos apply-node k8s-02 <ip> --insecure
            Each node will install Talos to disk, then reboot automatically.
            Once a node reboots you can detach the ISO in Proxmox — Talos
            boots from disk from this point on and the ISO is never needed again.
            Wait for all 3 nodes to reach "booting" stage before continuing.

    Step 6  Generate talosconfig:
              just talos gen-talosconfig

    Step 7  Bootstrap etcd (ONCE):
              just talos bootstrap

    Step 8  Validate nodes are up:
              just bootstrap check-nodes
              just bootstrap check-etcd

    Step 9  Get kubeconfig:
              just talos get-kubeconfig

    Step 10 Bootstrap the cluster (Cilium + Flux):
              just bootstrap all

    Step 11 Validate Kubernetes:
              just bootstrap check-k8s

    Step 12 Watch Flux deploy everything:
            KUBECONFIG=secrets/kubeconfig flux get kustomizations -A --watch

    ══════════════════════════════════════════════════════
    EOF
