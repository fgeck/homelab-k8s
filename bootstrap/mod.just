set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()
kubeconfig    := source_directory() + '/../secrets/kubeconfig'
age_key       := env('HOME') + '/.age/key.txt'
flux_key      := env('HOME') + '/.ssh/fluxGithubReadKeyK8s'
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

# Bootstrap Kubernetes components: namespaces → bootstrap secrets → CRDs → Cilium + CoreDNS → Flux controllers → Flux sources
kubernetes: _namespaces _sops-secret _crds _cilium-coredns _flux-controllers flux

# Apply namespace manifests
[private]
_namespaces:
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f "{{bootstrap_dir}}/namespaces.yaml"

# Render and apply bootstrap secrets
[private]
_sops-secret:
    minijinja-cli --autoescape=none "{{bootstrap_dir}}/resources.yaml.j2" \
        -D "agekey=$(grep -v '^#' '{{age_key}}' | base64 | tr -d '\n')" \
        -D "flux_identity=$(base64 -i '{{flux_key}}' | tr -d '\n')" \
        -D "flux_identity_pub=$(base64 -i '{{flux_key}}.pub' | tr -d '\n')" \
        -D "secrets_identity=$(base64 -i '{{secrets_key}}' | tr -d '\n')" \
        -D "secrets_identity_pub=$(base64 -i '{{secrets_key}}.pub' | tr -d '\n')" \
        -D "github_known_hosts=$(ssh-keyscan github.com 2>/dev/null | base64 | tr -d '\n')" \
        | KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f -

# Install bootstrap CRDs required before Flux app reconciliation
[private]
_crds:
    # Fresh control planes can be slow to serve long CRD apply requests; retry once.
    helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.d/00-crds.yaml" template \
        | yq ea -e 'select(.kind == "CustomResourceDefinition")' \
        | KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false --request-timeout=2m -f - \
        || (sleep 5 && \
            helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.d/00-crds.yaml" template \
                | yq ea -e 'select(.kind == "CustomResourceDefinition")' \
                | KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false --request-timeout=2m -f -)

# Install Cilium + CoreDNS via helmfile
[private]
_cilium-coredns:
    helmfile --kubeconfig "$(realpath "{{kubeconfig}}")" -f "{{bootstrap_dir}}/helmfile.yaml" sync

# Install Flux controllers directly, bypassing the chart's pre-install hook deadlock.
[private]
_flux-controllers:
    helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm upgrade --install flux2 fluxcd-community/flux2 \
        --version 2.18.3 \
        --kubeconfig "$(realpath "{{kubeconfig}}")" \
        --namespace flux-system \
        --create-namespace \
        --values "{{bootstrap_dir}}/../clusters/building-blocks/base/apps/flux/app/helm-values.yaml" \
        --wait \
        --timeout 5m \
        --no-hooks

# Register Flux sources and root Kustomizations
flux:
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f "{{bootstrap_dir}}/flux-gitrepository.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f "{{bootstrap_dir}}/flux-ks.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f "{{bootstrap_dir}}/secrets-gitrepository.yaml"
    KUBECONFIG={{kubeconfig}} kubectl apply --server-side --validate=false -f "{{bootstrap_dir}}/secrets-ks.yaml"
