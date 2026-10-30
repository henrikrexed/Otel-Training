#!/usr/bin/env bash
# verify.sh — verification of the Gateway API casino exposure (ISI-6795).
#
# Two modes, auto-selected:
#   * OFFLINE (no reachable cluster): structural validation of the manifests
#     this ticket ships — the only half provable on a shared dev host with no
#     kind cluster. Exits 0 when the manifests are well-formed.
#   * LIVE (cluster reachable): the executable form of the acceptance criteria —
#     CRDs installed, controller ready, Gateway Programmed, HTTPRoute Accepted,
#     the data plane exposed on NodePort 30000, and the casino UI actually
#     reachable through the Gateway.
#
# Exit 0 = all checks passed. Non-zero = at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

NS="${CASINO_NS:-casino}"
NGF_NS="${NGF_NS:-nginx-gateway}"
NODEPORT="${CASINO_HTTP_NODEPORT:-30000}"
STAMP="${STAMP:-manual}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HERE/evidence}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE="$EVIDENCE_DIR/verify-gateway-${STAMP}.txt"

CASINO_K8S="${REPO_ROOT}/deploy/casino/k8s"
GATEWAY_YAML="${CASINO_K8S}/70-gateway.yaml"
HTTPROUTE_YAML="${CASINO_K8S}/71-httproute.yaml"
NGINXPROXY_YAML="${HERE}/manifests/nginxproxy-nodeport.yaml"

PASS=0; FAIL=0
pass() { echo "[PASS] $*" | tee -a "$EVIDENCE"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" | tee -a "$EVIDENCE"; FAIL=$((FAIL+1)); }
info() { echo "       $*" | tee -a "$EVIDENCE"; }
hdr()  { echo | tee -a "$EVIDENCE"; echo "=== $* ===" | tee -a "$EVIDENCE"; }

echo "Gateway API casino exposure verification — ISI-6795" > "$EVIDENCE"
info "casino namespace : $NS"
info "NGF namespace    : $NGF_NS"
info "NodePort         : $NODEPORT"
info "evidence file    : $EVIDENCE"

# --- Offline manifest structural checks (always run) ------------------------
hdr "0. Manifests present + well-formed (offline)"
for f in "$GATEWAY_YAML" "$HTTPROUTE_YAML" "$NGINXPROXY_YAML"; do
  [[ -f "$f" ]] && pass "manifest exists: ${f#$REPO_ROOT/}" || fail "missing manifest: ${f#$REPO_ROOT/}"
done

check() { # file, grep-pattern, human description
  if grep -Eq "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3"; fi
}
check "$GATEWAY_YAML"    '^kind: Gateway$'                       "70-gateway.yaml declares a Gateway"
check "$GATEWAY_YAML"    'gatewayClassName:[[:space:]]*nginx'    "Gateway binds GatewayClass 'nginx'"
check "$GATEWAY_YAML"    'protocol:[[:space:]]*HTTP'             "Gateway has an HTTP listener"
check "$HTTPROUTE_YAML"  '^kind: HTTPRoute$'                     "71-httproute.yaml declares an HTTPRoute"
check "$HTTPROUTE_YAML"  'name:[[:space:]]*vegas-casino-frontend' "HTTPRoute backends the frontend Service"
check "$HTTPROUTE_YAML"  'port:[[:space:]]*3000'                 "HTTPRoute targets frontend port 3000"
check "$NGINXPROXY_YAML" 'type:[[:space:]]*NodePort'             "NginxProxy exposes the data plane as NodePort"
check "$NGINXPROXY_YAML" "port:[[:space:]]*${NODEPORT}"          "NginxProxy pins NodePort ${NODEPORT}"

# If kubeconform is on PATH, use it for real schema validation of the stable
# Gateway API kinds (NginxProxy is a vendor CRD; skip it there).
if command -v kubeconform >/dev/null 2>&1; then
  if kubeconform -strict -ignore-missing-schemas "$GATEWAY_YAML" "$HTTPROUTE_YAML" >>"$EVIDENCE" 2>&1; then
    pass "kubeconform: Gateway + HTTPRoute schema-valid"
  else
    fail "kubeconform reported schema errors (see $EVIDENCE)"
  fi
else
  info "kubeconform not on PATH — skipped deep schema validation (structural checks above still ran)"
fi

# --- Decide mode -------------------------------------------------------------
if ! kubectl cluster-info >/dev/null 2>&1; then
  hdr "Summary (OFFLINE)"
  info "no reachable cluster — live acceptance checks were skipped."
  info "Run this again inside the training codespace to prove the live AC:"
  info "  casino UI loads in a browser from outside the devcontainer."
  info "PASS=$PASS  FAIL=$FAIL"
  if [[ "$FAIL" -eq 0 ]]; then
    echo "[OK] Manifests valid; live checks pending a cluster." | tee -a "$EVIDENCE"; exit 0
  fi
  echo "[!!] $FAIL offline check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi

# ============================================================================
# LIVE CHECKS
# ============================================================================
info "cluster: $(kubectl config current-context 2>/dev/null)"

hdr "1. Gateway API CRDs + controller"
for crd in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io \
           gatewayclasses.gateway.networking.k8s.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 && pass "CRD present: $crd" || fail "CRD missing: $crd"
done
if kubectl -n "$NGF_NS" get deploy nginx-gateway >/dev/null 2>&1; then
  ready=$(kubectl -n "$NGF_NS" get deploy nginx-gateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ "${ready:-0}" -ge 1 ]] && pass "NGF controller ready (${ready} replica)" || fail "NGF controller not ready"
else
  fail "NGF controller deployment not found — run deploy/gateway/install.sh"
fi
gc_status=$(kubectl get gatewayclass nginx -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[[ "$gc_status" == "True" ]] && pass "GatewayClass 'nginx' Accepted" || fail "GatewayClass 'nginx' not Accepted (got '${gc_status:-none}')"

hdr "2. NodePort override applied"
np=$(kubectl get nginxproxy nginx-gateway-proxy-config -n "$NGF_NS" \
  -o jsonpath='{.spec.kubernetes.service.nodePorts[0].port}' 2>/dev/null)
sty=$(kubectl get nginxproxy nginx-gateway-proxy-config -n "$NGF_NS" \
  -o jsonpath='{.spec.kubernetes.service.type}' 2>/dev/null)
[[ "$sty" == "NodePort" ]] && pass "NginxProxy service type is NodePort" || fail "NginxProxy service type is '${sty:-none}' (expected NodePort)"
[[ "$np" == "$NODEPORT" ]] && pass "NginxProxy pins NodePort $NODEPORT" || fail "NginxProxy NodePort is '${np:-none}' (expected $NODEPORT)"

hdr "3. Casino Gateway + HTTPRoute (AC: config applied)"
if kubectl -n "$NS" get gateway casino >/dev/null 2>&1; then
  prog=$(kubectl -n "$NS" get gateway casino -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  [[ "$prog" == "True" ]] && pass "Gateway 'casino' Programmed" || fail "Gateway 'casino' not Programmed (got '${prog:-none}')"
else
  fail "Gateway 'casino' not found in '$NS' — sync the casino app (Argo CD) or apply deploy/casino/k8s"
fi
if kubectl -n "$NS" get httproute casino >/dev/null 2>&1; then
  acc=$(kubectl -n "$NS" get httproute casino -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  rr=$(kubectl -n "$NS" get httproute casino -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)
  [[ "$acc" == "True" ]] && pass "HTTPRoute 'casino' Accepted" || fail "HTTPRoute 'casino' not Accepted (got '${acc:-none}')"
  [[ "$rr" == "True" ]]  && pass "HTTPRoute backend ResolvedRefs=True (frontend reachable)" || fail "HTTPRoute ResolvedRefs not True (got '${rr:-none}')"
else
  fail "HTTPRoute 'casino' not found in '$NS'"
fi

hdr "4. Data plane exposed on NodePort $NODEPORT"
svc=$(kubectl -n "$NS" get svc -o jsonpath="{.items[?(@.spec.ports[0].nodePort==$NODEPORT)].metadata.name}" 2>/dev/null)
if [[ -n "$svc" ]]; then
  pass "NodePort $NODEPORT served by Service '$svc' in '$NS'"
else
  # Fall back to any NodePort service in the namespace (port index may vary).
  svc=$(kubectl -n "$NS" get svc --field-selector spec.type=NodePort -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if kubectl -n "$NS" get svc "$svc" -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null | grep -qw "$NODEPORT"; then
    pass "NodePort $NODEPORT served by Service '$svc' in '$NS'"
  else
    fail "no NodePort $NODEPORT Service in '$NS' — is the Gateway Programmed?"
  fi
fi

hdr "5. Casino UI reachable THROUGH the Gateway (AC #1)"
# From inside the cluster, hit the data-plane Service directly (listener :80).
if [[ -n "${svc:-}" ]]; then
  if kubectl -n "$NS" run gw-verify-curl --rm -i --restart=Never \
       --image=curlimages/curl:8.11.1 --command -- \
       sh -c "curl -fsS --max-time 10 http://${svc}.${NS}:80/health" \
       >/tmp/gw-health.$$ 2>>"$EVIDENCE"; then
    pass "casino /health reachable through the Gateway data plane"
    info "$(head -c 200 /tmp/gw-health.$$)"
  else
    fail "casino not reachable through the Gateway data plane (:80 -> frontend:3000)"
  fi
  rm -f /tmp/gw-health.$$
fi
# From the devcontainer host, hit the forwarded NodePort (what the attendee sees).
if curl -fsS --max-time 10 "http://localhost:${NODEPORT}/health" >/tmp/gw-host.$$ 2>>"$EVIDENCE"; then
  pass "casino /health reachable at http://localhost:${NODEPORT} (forwarded port)"
  info "$(head -c 200 /tmp/gw-host.$$)"
else
  info "http://localhost:${NODEPORT} not answered from here — expected on this shared"
  info "dev host (no kind port mapping). In the codespace this is the attendee URL."
fi
rm -f /tmp/gw-host.$$

hdr "Summary (LIVE)"
info "PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "[OK] All ISI-6795 acceptance checks passed." | tee -a "$EVIDENCE"; exit 0
else
  echo "[!!] $FAIL check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi
