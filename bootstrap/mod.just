set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()
kubeconfig    := source_directory() + '/../secrets/kubeconfig'
age_key       := env('HOME') + '/.age/key.txt'
secrets_key   := env('HOME') + '/.ssh/fluxGithubReadKeyK8sSecrets'

[private]
default:
    just bootstrap -l

# Check Kubernetes nodes are Ready
check-k8s:
    [[ -f "{{kubeconfig}}" ]] || { echo "ERROR: run: just talos get-kubeconfig"; exit 1; }
    KUBECONFIG={{kubeconfig}} kubectl get nodes -o wide
    KUBECONFIG={{kubeconfig}} kubectl get pods -n kube-system -o wide

# ─── BOOTSTRAP ────────────────────────────────────────────────────────────────

# Bootstrap Kubernetes components: namespaces → bootstrap secrets → CRDs → Cilium + CoreDNS + Flux → Flux sources
kubernetes: _namespaces _sops-secret _crds _cilium-coredns flux

# Apply namespace manifests
[private]
_namespaces:
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/namespaces.yaml"

# Render and apply bootstrap secrets
[private]
_sops-secret:
    minijinja-cli --autoescape=none "{{bootstrap_dir}}/resources.yaml.j2" \
        -D "agekey=$(grep -v '^#' '{{age_key}}' | base64 | tr -d '\n')" \
        -D "secrets_identity=$(base64 -i '{{secrets_key}}' | tr -d '\n')" \
        -D "secrets_identity_pub=$(base64 -i '{{secrets_key}}.pub' | tr -d '\n')" \
        -D "github_known_hosts=$(ssh-keyscan github.com 2>/dev/null | base64 | tr -d '\n')" \
        | KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f -

# Install bootstrap CRDs required before Flux app reconciliation
[private]
_crds:
    helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.d/00-crds.yaml" template \
        | yq ea -e 'select(.kind == "CustomResourceDefinition")' \
        | KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f -

# Install Cilium + CoreDNS + Flux via helmfile
[private]
_cilium-coredns:
    helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.yaml" sync

# Register Flux sources and root Kustomizations
flux:
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/flux-gitrepository.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/flux-ks.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/secrets-gitrepository.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side -f "{{bootstrap_dir}}/secrets-ks.yaml"
