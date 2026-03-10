#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*" >&2; exit 1; }

# ── 1. dependencies ────────────────────────────────────────────────────────────
info "Checking dependencies..."

MISSING=()
command -v kubectl &>/dev/null || MISSING+=(kubectl)
command -v helm    &>/dev/null || MISSING+=(helm)

if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "Installing via pacman: ${MISSING[*]}"
  sudo pacman -S --noconfirm --needed "${MISSING[@]}"
fi

success "kubectl $(kubectl version --client -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
success "helm    $(helm version --short)"

# ── 2. secrets.env ─────────────────────────────────────────────────────────────
SECRETS_FILE="$SCRIPT_DIR/secrets.env"

[[ -f "$SECRETS_FILE" ]] || die "secrets.env not found. Copy secrets.env.example to secrets.env and fill it in."

# shellcheck source=/dev/null
source "$SECRETS_FILE"

[[ -n "$CF_API_TOKEN" ]] || die "CF_API_TOKEN is not set in secrets.env"

# ── 3. validate values files ───────────────────────────────────────────────────
info "Validating values files..."

VALUES_FILES=(
  "$SCRIPT_DIR/externaldns/values.yaml"
  "$SCRIPT_DIR/monitoring/values.yaml"
)

PLACEHOLDER_ERRORS=()
for f in "${VALUES_FILES[@]}"; do
  if grep -qP '<[^>]+>' "$f" 2>/dev/null; then
    unfilled=$(grep -oP '<[^>]+>' "$f" | sort -u | tr '\n' ' ')
    PLACEHOLDER_ERRORS+=("  ${f##"$SCRIPT_DIR"/}: ${unfilled}")
  fi
done

if [[ ${#PLACEHOLDER_ERRORS[@]} -gt 0 ]]; then
  die "Unfilled placeholders found — edit the files before running bootstrap:\n$(printf '%s\n' "${PLACEHOLDER_ERRORS[@]}")"
fi

success "Values files look good"

# ── 4. cluster connectivity ────────────────────────────────────────────────────
info "Verifying cluster connectivity..."
kubectl cluster-info &>/dev/null || die "kubectl cannot reach the cluster. Check your kubeconfig."
success "Cluster reachable: $(kubectl config current-context)"

# ── 5. install argocd ──────────────────────────────────────────────────────────
echo
echo -e "${BLUE}━━━ ArgoCD ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Installing ArgoCD..."

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

info "Waiting for ArgoCD server..."
kubectl wait --namespace argocd \
  --for=condition=available deployment/argocd-server \
  --timeout=120s

success "ArgoCD ready"

# ── 6. namespaces ──────────────────────────────────────────────────────────────
info "Creating namespaces..."

for ns in cert-manager ssl-dns-management monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

success "Namespaces ready"

# ── 7. secrets ────────────────────────────────────────────────────────────────
info "Creating secrets..."

for ns in cert-manager ssl-dns-management; do
  kubectl create secret generic cloudflare-api-token-secret \
    --namespace "$ns" \
    --from-literal=api-token="$CF_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
done

success "Secrets applied"

# ── 8. argocd applications ─────────────────────────────────────────────────────
echo
echo -e "${BLUE}━━━ Deploying Applications ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Applying ArgoCD applications..."

kubectl apply -f "$SCRIPT_DIR/argocd/"

success "Applications submitted"

# ── 9. summary ────────────────────────────────────────────────────────────────
echo
echo -e "${BLUE}━━━ Done ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo "  ArgoCD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    URL:      https://localhost:8080"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<not yet available>")
echo "    User:     admin"
echo "    Password: ${ARGOCD_PASS}"
echo
echo "  Watch sync status:"
echo "    kubectl get applications -n argocd -w"
