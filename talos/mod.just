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
    case "{{node}}" in
        nas)    just talos _secrets | yq '.data.nodes.nas.ip' ;;
        k8s-01) just talos _secrets | yq '.data.nodes["k8s-01"].ip' ;;
        k8s-02) just talos _secrets | yq '.data.nodes["k8s-02"].ip' ;;
        vip)    just talos _secrets | yq '.data.network.vip' ;;
        *) echo "Unknown node: {{node}}" >&2; exit 1 ;;
    esac

# ─── SCHEMATIC ───────────────────────────────────────────────────────────────

# Submit schematic.yaml to the image factory and print the schematic ID
schematic-id:
    curl -sX POST --data-binary @{{talos_dir}}/schematic.yaml https://factory.talos.dev/schematics | yq '.id'

# Print ISO and installer URLs for the current schematic + version
installer-url:
    #!/usr/bin/env bash
    id=$(yq '.schematicId' "{{values}}")
    ver=$(yq '.talosVersion' "{{values}}")
    echo "ISO:       https://factory.talos.dev/image/$id/$ver/metal-amd64.iso"
    echo "Installer: factory.talos.dev/installer/$id:$ver"

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

    VIP=$(yq '.network.vip'           "{{talos_dir}}/network.yaml")
    GW=$(yq '.network.gateway'        "{{talos_dir}}/network.yaml")
    SUBNET=$(yq '.network.nodeSubnet' "{{talos_dir}}/network.yaml")
    PREFIX=$(yq '.network.nodePrefix' "{{talos_dir}}/network.yaml")
    NAS=$(yq '.nodes.nas.ip'          "{{talos_dir}}/network.yaml")
    K8S01=$(yq '.nodes["k8s-01"].ip'  "{{talos_dir}}/network.yaml")
    K8S02=$(yq '.nodes["k8s-02"].ip'  "{{talos_dir}}/network.yaml")

    yq "{
      \"data\": {
        \"machine\":        {\"ca\": {\"crt\": .certs.os.crt, \"key\": .certs.os.key}, \"token\": .trustdinfo.token},
        \"cluster\":        {\"id\": .cluster.id, \"secret\": .cluster.secret, \"token\": .secrets.bootstraptoken,
                             \"ca\": {\"crt\": .certs.k8s.crt, \"key\": .certs.k8s.key},
                             \"aggregatorCA\": {\"crt\": .certs.k8saggregator.crt, \"key\": .certs.k8saggregator.key},
                             \"etcd\": {\"ca\": {\"crt\": .certs.etcd.crt, \"key\": .certs.etcd.key}}},
        \"secrets\":        {\"secretboxencryptionsecret\": .secrets.secretboxencryptionsecret},
        \"serviceAccount\": {\"key\": .certs.k8sserviceaccount.key},
        \"network\":        {\"vip\": \"$VIP\", \"gateway\": \"$GW\", \"nodeSubnet\": \"$SUBNET\", \"nodePrefix\": \"$PREFIX\"},
        \"nodes\":          {\"nas\": {\"ip\": \"$NAS\"}, \"k8s-01\": {\"ip\": \"$K8S01\"}, \"k8s-02\": {\"ip\": \"$K8S02\"}}
      }
    }" "$raw" > "{{secrets}}"

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
        "{{talos_dir}}/patches/{{node}}.yaml.j2" "$tmp/secrets.yaml" "{{values}}" -o "$tmp/patch.yaml"
    talosctl machineconfig patch "$tmp/base.yaml" --patch "@$tmp/patch.yaml"

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

    # Convert our custom data: wrapper back to the raw Talos secrets bundle format
    yq '{
      "version": "v1alpha1",
      "trustdinfo": {"token": .data.machine.token},
      "certs": {
        "etcd":             {"crt": .data.cluster.etcd.ca.crt,      "key": .data.cluster.etcd.ca.key},
        "k8s":              {"crt": .data.cluster.ca.crt,            "key": .data.cluster.ca.key},
        "k8saggregator":    {"crt": .data.cluster.aggregatorCA.crt,  "key": .data.cluster.aggregatorCA.key},
        "k8sserviceaccount":{"key": .data.serviceAccount.key},
        "os":               {"crt": .data.machine.ca.crt,            "key": .data.machine.ca.key}
      },
      "cluster": {"id": .data.cluster.id, "secret": .data.cluster.secret},
      "secrets": {
        "bootstraptoken":             .data.cluster.token,
        "secretboxencryptionsecret":  .data.secrets.secretboxencryptionsecret
      }
    }' "$tmp/secrets.yaml" > "$tmp/talos-bundle.yaml"

    talosctl gen config \
        --with-secrets "$tmp/talos-bundle.yaml" \
        --output-types talosconfig --output "{{talosconfig}}" --force \
        main "https://$(yq '.data.network.vip' "$tmp/secrets.yaml"):6443"
    talosctl --talosconfig="{{talosconfig}}" config endpoint \
        "$(yq '.data.nodes.nas.ip' "$tmp/secrets.yaml")" \
        "$(yq '.data.nodes["k8s-01"].ip' "$tmp/secrets.yaml")" \
        "$(yq '.data.nodes["k8s-02"].ip' "$tmp/secrets.yaml")"
    # config node sets the default target for talosctl commands (no -n flag needed).
    # k8s-01 is the default; override per-command with: talosctl -n <ip> ...
    talosctl --talosconfig="{{talosconfig}}" config node \
        "$(yq '.data.nodes["k8s-01"].ip' "$tmp/secrets.yaml")"
    echo "talosconfig → secrets/talosconfig"

# Bootstrap etcd — run ONCE on nas after all nodes are up
bootstrap:
    talosctl bootstrap --talosconfig="{{talosconfig}}" \
        --nodes "$(just talos _ip nas)" --endpoints "$(just talos _ip nas)"

# Wait for cluster health
health:
    talosctl health --talosconfig="{{talosconfig}}" \
        --control-plane-nodes "$(just talos _ip nas),$(just talos _ip k8s-01),$(just talos _ip k8s-02)"

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
    talosctl upgrade --talosconfig="{{talosconfig}}" \
        --nodes "$(just talos _ip {{node}})" \
        --image "factory.talos.dev/installer/$(yq '.schematicId' "{{values}}"):$(yq '.talosVersion' "{{values}}")"

# Upgrade Kubernetes version across the cluster
upgrade-k8s:
    talosctl upgrade-k8s --talosconfig="{{talosconfig}}" \
        --nodes "$(just talos _ip k8s-01)" \
        --to "$(yq '.kubernetesVersion' "{{values}}")"

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
