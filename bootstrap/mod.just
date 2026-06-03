set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()
kubeconfig    := source_directory() + '/../secrets/kubeconfig'
age_key       := env('HOME') + '/.age/key.txt'

[private]
default:
    just bootstrap -l

# Check Kubernetes nodes are Ready
check-k8s:
    [[ -f "{{kubeconfig}}" ]] || { echo "ERROR: run: just talos get-kubeconfig"; exit 1; }
    KUBECONFIG={{kubeconfig}} kubectl get nodes -o wide
    KUBECONFIG={{kubeconfig}} kubectl get pods -n kube-system -o wide

# ─── BOOTSTRAP ────────────────────────────────────────────────────────────────

# Bootstrap Kubernetes components: namespaces → sops secret → Cilium + CoreDNS → Flux
kubernetes: _namespaces _sops-secret _cilium-coredns flux

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
