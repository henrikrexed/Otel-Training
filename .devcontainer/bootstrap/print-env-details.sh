#!/usr/bin/env bash
# print-env-details.sh — friendly "where do I log in?" summary for the OTel
# Training codespace (ISI-7932 / GH #170).
#
# Prints the live URL + credentials for every tool a participant needs so they
# never have to grep scripts/manifests for a password again:
#
#   Argo CD · Gitea · casino · Dynatrace
#
# Design contract (all four are load-bearing — do not relax without re-reading
# the issue):
#   * READ-ONLY / idempotent — only `kubectl get` and reads; it changes NO
#     cluster state, so it is safe to run as many times as you like.
#   * Secrets are read LIVE from the cluster (kubectl ... | base64 -d) so the
#     output stays correct after every rebuild — nothing credential-bearing is
#     baked into this file.
#   * Fails GRACEFULLY per tool ("not installed yet") instead of aborting, so a
#     half-deployed environment still prints what IS up.
#   * Prints ONLY to stdout. It deliberately writes NOTHING to the evidence
#     bundle (.devcontainer/evidence) — participants attach that bundle to
#     issues, and the Argo CD / Gitea passwords must never leak there.
#
# Re-run any time:
#   bash .devcontainer/bootstrap/print-env-details.sh
#
# NOTE: `set -e` is intentionally OFF. Each tool section must be able to fail
# (CRD missing, namespace absent, tenant unset) and still let the next one run.
set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
GITEA_NAMESPACE="${GITEA_NAMESPACE:-gitea}"
CASINO_NAMESPACE="${CASINO_NAMESPACE:-casino}"

# Gitea admin login is NOT stored in a cluster secret — seed-gitea.sh creates it
# from these same deterministic defaults (override via env to match a custom
# seed). Keep the fallbacks in lock-step with gitops/install/seed-gitea.sh.
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"

# Dynatrace cluster NAME as it appears under Kubernetes -> Clusters is the
# DynaKube name, which derives from the kind cluster / PARTICIPANT_ID exactly as
# deploy/dynatrace/install.sh resolves it (ISI-7654 per-attendee cluster name).
DYNAKUBE_NAME="${DYNAKUBE_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}"

# --- Pretty output (degrade to plain text when not a TTY) --------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; DIM=""; RST=""
fi

section() { echo; echo "${BOLD}▸ $1${RST}"; }
kv()      { printf "    %-12s %s\n" "$1" "$2"; }
missing() { printf "    %snot installed yet%s — %s\n" "$YELLOW" "$RST" "$1"; }

# have_ns <namespace> — true when the namespace exists (cheap reachability + "is
# this tool deployed?" probe rolled into one; also catches a dead cluster).
have_ns() { $KUBECTL get namespace "$1" >/dev/null 2>&1; }

echo "${BOLD}================================================================${RST}"
echo "${BOLD} OTel Training — your environment details${RST}"
echo "${BOLD}================================================================${RST}"
echo "${DIM} Live URLs + logins, read straight from the cluster. Read-only;${RST}"
echo "${DIM} re-run any time: bash .devcontainer/bootstrap/print-env-details.sh${RST}"

if ! $KUBECTL version >/dev/null 2>&1 && ! $KUBECTL cluster-info >/dev/null 2>&1; then
  echo
  echo "    ${YELLOW}Cannot reach the kind cluster${RST} — has bring-up finished?"
  echo "    Run:  bash .devcontainer/bootstrap/deploy-environment.sh"
  echo "${BOLD}================================================================${RST}"
  exit 0
fi

# --- Argo CD -----------------------------------------------------------------
section "Argo CD  (GitOps control plane)"
if have_ns "$ARGOCD_NAMESPACE"; then
  argo_pw="$($KUBECTL -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
  kv "URL"      "http://localhost:30002"
  kv "username" "admin"
  if [[ -n "$argo_pw" ]]; then
    kv "password" "$argo_pw"
  else
    kv "password" "${YELLOW}secret argocd-initial-admin-secret not found yet${RST}"
  fi
else
  missing "namespace '$ARGOCD_NAMESPACE' absent (run deploy-environment.sh)"
fi

# --- Gitea -------------------------------------------------------------------
section "Gitea  (in-cluster git host + container registry)"
if have_ns "$GITEA_NAMESPACE"; then
  kv "URL"      "http://localhost:30001"
  kv "username" "$GITEA_ADMIN_USER"
  kv "password" "$GITEA_ADMIN_PASS"
  kv "registry" "gitea.local:30001  (in-cluster) / localhost:30001  (from the codespace)"
  echo "    ${DIM}casino repo: http://localhost:30001/casino/casino${RST}"
else
  missing "namespace '$GITEA_NAMESPACE' absent — using the GitLab fork instead? (GITOPS_PROVIDER=gitlab)"
fi

# --- Casino ------------------------------------------------------------------
section "Casino app  (the workshop's demo application)"
if have_ns "$CASINO_NAMESPACE"; then
  kv "URL"   "http://localhost:30000"
  kv "login" "register a player in the UI — the login is fake, use made-up values"
else
  missing "namespace '$CASINO_NAMESPACE' absent (run deploy-environment.sh)"
fi

# --- Dynatrace ---------------------------------------------------------------
section "Dynatrace  (observability backend)"
if [[ "${DT_TENANT:-}" == https://* ]]; then
  tenant="${DT_TENANT%/}"
  kv "tenant"  "$tenant"
  kv "cluster" "$DYNAKUBE_NAME   ${DIM}(Kubernetes -> Clusters)${RST}"
  echo "    ${DIM}clusters app: ${tenant}/ui/apps/dynatrace.kubernetes (filter for '$DYNAKUBE_NAME')${RST}"
else
  missing "DT_TENANT not set — Dynatrace labs run in no-export mode"
  echo "    ${DIM}set DT_TENANT / DT_OPERATOR_TOKEN / DT_INGEST_TOKEN in .env and re-run bring-up${RST}"
fi

echo
echo "${BOLD}================================================================${RST}"
exit 0
