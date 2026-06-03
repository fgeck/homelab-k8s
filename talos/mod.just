set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir   := source_directory()
values      := talos_dir + '/values.yaml'
secrets     := talos_dir + '/talos-secrets.sops.yaml'
age_key     := env('HOME') + '/.age/key.txt'
talosconfig := source_directory() + '/../secrets/talosconfig'
kubeconfig  := source_directory() + '/../secrets/kubeconfig'

[private]
default:
    just talos -l

# ─── PRIVATE HELPERS ─────────────────────────────────────────────────────────

# Decrypt secrets to stdout (or pass through if not yet encrypted)
[private]
_secrets:
    #!/usr/bin/env bash
    if grep -q '^[[:space:]]*sops:' "{{secrets}}"; then
        SOPS_AGE_KEY_FILE={{age_key}} sops -d "{{secrets}}"
    else
        cat "{{secrets}}"
    fi

# Get a node's IP from decrypted secrets. Usage: just talos _ip nas
[private]
_ip node:
    #!/usr/bin/env bash
    tmp=$(mktemp); trap "rm -f '$tmp'" EXIT
    just talos _secrets > "$tmp"
    minijinja-cli --format=yaml --no-newline --strict \
        "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp" \
        -D node="{{node}}"

# ─── SCHEMATIC ───────────────────────────────────────────────────────────────

# Submit schematic.yaml to the image factory and print the schematic ID
schematic-id:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp); trap "rm -f '$tmp'" EXIT
    curl -sX POST --data-binary @{{talos_dir}}/schematic.yaml https://factory.talos.dev/schematics > "$tmp"
    minijinja-cli --format=json --no-newline --strict \
        "{{talos_dir}}/templates/schematic-id.txt.j2" "$tmp"

# Print ISO and installer URLs for the current schematic + version
installer-url:
    minijinja-cli --strict "{{talos_dir}}/templates/installer-urls.txt.j2" "{{values}}"

# ─── SECRETS ─────────────────────────────────────────────────────────────────

# Generate cluster secrets and encrypt into talos-secrets.sops.yaml.
# No-op if secrets already exist — run 'just sops edit talos/talos-secrets.sops.yaml' to update.
gen-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f "{{secrets}}" ]] && grep -q '^[[:space:]]*sops:' "{{secrets}}"; then
        gum style --foreground 212 "Secrets already exist and are encrypted — nothing to do."
        echo "To update: just sops edit talos/talos-secrets.sops.yaml"
        exit 0
    fi

    [[ -f "{{talos_dir}}/network.yaml" ]] || { gum style --foreground 196 "ERROR: create talos/network.yaml from talos/network.yaml.example first"; exit 1; }

    raw=$(mktemp); trap "rm -f '$raw'" EXIT
    talosctl gen secrets --force -o "$raw"

    minijinja-cli --format=yaml --trim-blocks --lstrip-blocks --autoescape=none --strict \
        "{{talos_dir}}/templates/secrets-wrapper.yaml.j2" "$raw" "{{talos_dir}}/network.yaml" \
        -o "{{secrets}}"

    SOPS_AGE_KEY_FILE={{age_key}} sops --encrypt --in-place "{{secrets}}"
    gum style --foreground 212 "Secrets written and encrypted → talos/talos-secrets.sops.yaml"

# ─── RENDER ──────────────────────────────────────────────────────────────────

# Render machine config for a node and print to stdout
render-config node:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    just talos _secrets > "$tmp/secrets.yaml"
    minijinja-cli --trim-blocks --lstrip-blocks --autoescape=none \
        "{{talos_dir}}/machineconfig.yaml.j2" "$tmp/secrets.yaml" "{{values}}" -o "$tmp/base.yaml"
    minijinja-cli --trim-blocks --lstrip-blocks --autoescape=none \
        "{{talos_dir}}/patches/machine/{{node}}.yaml.j2" "$tmp/secrets.yaml" "{{values}}" -o "$tmp/patch.yaml"
    talosctl machineconfig patch "$tmp/base.yaml" --patch "@$tmp/patch.yaml" > "$tmp/rendered.yaml"
    config_doc_tpl="{{talos_dir}}/patches/config/{{node}}.yaml.j2"
    if [ -f "$config_doc_tpl" ]; then
        minijinja-cli --trim-blocks --lstrip-blocks --autoescape=none \
            "$config_doc_tpl" "$tmp/secrets.yaml" "{{values}}" -o "$tmp/config-doc.yaml"
        cat "$tmp/config-doc.yaml" >> "$tmp/rendered.yaml"
    fi
    cat "$tmp/rendered.yaml"

# ─── APPLY ───────────────────────────────────────────────────────────────────

# Render and apply config to a node. Usage: just talos apply-node nas 192.168.1.21 [--insecure]
apply-node node ip *args:
    just talos render-config "{{node}}" | talosctl apply-config \
        --nodes "{{ip}}" --endpoints "{{ip}}" --file /dev/stdin {{args}}
    echo "Config applied to {{node}} ({{ip}})"

# ─── BOOTSTRAP ───────────────────────────────────────────────────────────────

# Generate talosconfig pointing at VIP + all node IPs
gen-talosconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$(dirname "{{talosconfig}}")"
    tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    just talos _secrets > "$tmp/secrets.yaml"

    minijinja-cli --format=yaml --trim-blocks --lstrip-blocks --autoescape=none --strict \
        "{{talos_dir}}/templates/talos-bundle.yaml.j2" "$tmp/secrets.yaml" \
        -o "$tmp/talos-bundle.yaml"

    talosctl gen config \
        --with-secrets "$tmp/talos-bundle.yaml" \
        --output-types talosconfig --output "{{talosconfig}}" --force \
        main "https://$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp/secrets.yaml" -D node=vip):6443"
    talosctl --talosconfig="{{talosconfig}}" config endpoint \
        "$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp/secrets.yaml" -D node=nas)" \
        "$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp/secrets.yaml" -D node=k8s-01)" \
        "$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp/secrets.yaml" -D node=k8s-02)"
    # config node sets the default target for talosctl commands (no -n flag needed).
    # k8s-01 is the default; override per-command with: talosctl -n <ip> ...
    talosctl --talosconfig="{{talosconfig}}" config node \
        "$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/node-ip.txt.j2" "$tmp/secrets.yaml" -D node=k8s-01)"
    echo "talosconfig → secrets/talosconfig"

# Bootstrap etcd — run ONCE on nas after all nodes are up
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    talosctl bootstrap --talosconfig="{{talosconfig}}" \
        --nodes "$(just talos _ip nas)" --endpoints "$(just talos _ip nas)"
    echo "Waiting for etcd to form quorum..."
    until talosctl etcd members --talosconfig="{{talosconfig}}" --nodes "$(just talos _ip nas)" &>/dev/null 2>&1; do
        sleep 3
    done
    talosctl etcd members --talosconfig="{{talosconfig}}" --nodes "$(just talos _ip nas)"
    echo "Bootstrap complete — etcd quorum established."

# Wait for cluster health
health:
    talosctl health --talosconfig="{{talosconfig}}" \
        --control-plane-nodes "$(just talos _ip nas),$(just talos _ip k8s-01),$(just talos _ip k8s-02)"

# Check all nodes are reachable via talosctl and report version + stage
check-nodes:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -f "{{talosconfig}}" ]] || { echo "ERROR: run: just talos gen-talosconfig"; exit 1; }
    rc=0
    for node in nas k8s-01 k8s-02; do
        ip=$(just talos _ip "$node")
        if out=$(talosctl --talosconfig="{{talosconfig}}" --nodes "$ip" --endpoints "$ip" version --short 2>&1); then
            stage=$(talosctl --talosconfig="{{talosconfig}}" get machinestatus \
                --nodes "$ip" --endpoints "$ip" 2>&1 | awk 'NR==2 {print $6}')
            echo "OK   $node ($ip) — version: $out — stage: ${stage:-unknown}"
        else
            echo "FAIL $node ($ip) — $out" >&2
            rc=1
        fi
    done
    exit $rc

# Check etcd health on controlplane nodes
check-etcd:
    [[ -f "{{talosconfig}}" ]] || { echo "ERROR: run: just talos gen-talosconfig"; exit 1; }
    talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip nas)" etcd members
    talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip nas)" etcd status

# Retrieve kubeconfig from the cluster
get-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$(dirname "{{kubeconfig}}")"
    # --force overwrites existing file instead of renaming the context to admin@main-1, -2, etc.
    talosctl kubeconfig --talosconfig="{{talosconfig}}" --force \
        --nodes "$(just talos _ip vip)" --endpoints "$(just talos _ip vip)" "{{kubeconfig}}"
    KUBECONFIG="{{kubeconfig}}" kubectl config use-context admin@main
    gum style --foreground 212 "kubeconfig → secrets/kubeconfig (context: admin@main)"

# ─── DAY-2 ───────────────────────────────────────────────────────────────────

# Upgrade Talos on a single node. Usage: just talos upgrade-node nas
upgrade-node node:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just talos _ip "{{node}}")
    image="$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/installer-image.txt.j2" "{{values}}")"
    talosctl version --talosconfig="{{talosconfig}}"
    gum confirm "Upgrade {{node}} ($ip) to $image ?"
    talosctl upgrade --talosconfig="{{talosconfig}}" \
        --nodes "$ip" --image "$image" --wait=false || true
    echo "Rebooting {{node}}..."
    boot_id=$(talosctl read /proc/sys/kernel/random/boot_id --talosconfig="{{talosconfig}}" --nodes "$ip" 2>/dev/null || true)
    talosctl reboot --talosconfig="{{talosconfig}}" --nodes "$ip" --wait=false
    echo "Waiting for {{node}} to reboot (boot_id: $boot_id)..."
    until [[ "$(talosctl read /proc/sys/kernel/random/boot_id --talosconfig="{{talosconfig}}" --nodes "$ip" 2>/dev/null)" != "$boot_id" ]]; do
        sleep 3
    done
    echo "{{node}} is back up."
    talosctl version --talosconfig="{{talosconfig}}" --nodes "$ip"

# Upgrade Kubernetes version across the cluster
upgrade-k8s:
    talosctl upgrade-k8s --talosconfig="{{talosconfig}}" \
        --nodes "$(just talos _ip k8s-01)" \
        --to "$(minijinja-cli --no-newline --strict "{{talos_dir}}/templates/kubernetes-version.txt.j2" "{{values}}")"

# Reset a node (destructive). Usage: just talos reset-node nas
reset-node node:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just talos _ip "{{node}}")
    gum confirm "Reset {{node}} ($ip)? This wipes STATE+EPHEMERAL and reboots." || exit 0
    talosctl --talosconfig="{{talosconfig}}" -n "$ip" reset \
        --reboot --graceful=false --wait=false \
        --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL

# Reset ALL nodes — wipes STATE+EPHEMERAL and reboots into maintenance mode. Usage: just talos reset-all
reset-all:
    #!/usr/bin/env bash
    set -euo pipefail
    gum confirm --affirmative="Yes, wipe all" --negative="Cancel" \
        "Reset ALL nodes (nas, k8s-01, k8s-02)? This wipes STATE+EPHEMERAL on every node." || exit 0
    for node in k8s-02 k8s-01 nas; do
        ip=$(just talos _ip "$node")
        gum spin --title "Resetting $node ($ip)..." -- \
            talosctl --talosconfig="{{talosconfig}}" -n "$ip" reset \
                --reboot --graceful=false --wait=false \
                --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL || \
            echo "  (could not reach $node — may already be down)"
        sleep 2
    done
    gum style --foreground 212 "All nodes are rebooting into maintenance mode."
    echo ""
    echo "Wait for DHCP IPs in Proxmox, then re-apply:"
    echo "  just talos apply-node nas    <dhcp-ip> --insecure"
    echo "  just talos apply-node k8s-01 <dhcp-ip> --insecure"
    echo "  just talos apply-node k8s-02 <dhcp-ip> --insecure"

# Defragment etcd on all controlplane nodes
etcd-defrag:
    #!/usr/bin/env bash
    set -euo pipefail
    for node in nas k8s-01 k8s-02; do
        echo "Defragging etcd on $node..."
        talosctl --talosconfig="{{talosconfig}}" -n "$(just talos _ip $node)" etcd defrag
    done
    echo "etcd defrag complete"
