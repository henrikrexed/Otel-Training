#!/usr/bin/env bash
# install-tools.sh — install the OTel-training Kubernetes toolchain.
#
# Idempotent: every installer checks `command -v` first and only (re)installs when
# missing or when FORCE=1. Versions are read from env vars so the same script is
# used at image build time (Dockerfile) and for runtime self-heal (postStart).
#
# Tools: kubectl, helm, kind, argocd, yq, dtctl, opencode  (jq/git come from apt)
set -euo pipefail

# Default pinned to the kind node image (kind-config.yaml); "stable" still works
# for standalone use and resolves dl.k8s.io/release/stable.txt dynamically.
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.31.2}"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"
KIND_VERSION="${KIND_VERSION:-v0.25.0}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.2}"
YQ_VERSION="${YQ_VERSION:-v4.44.6}"
DTCTL_VERSION="${DTCTL_VERSION:-v0.45.0}"   # Dynatrace/dtctl GoReleaser tag; "latest" resolves via API
DTCTL_REPO="${DTCTL_REPO:-Dynatrace/dtctl}"  # was dynatrace-oss/dtctl — repo moved to the Dynatrace org
OPENCODE_VERSION="${OPENCODE_VERSION:-v1.19.5}"  # sst/opencode release tag; "latest" resolves via API
OPENCODE_REPO="${OPENCODE_REPO:-sst/opencode}"
FORCE="${FORCE:-0}"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
# Pick the right sudo prefix: root needs none, non-root uses sudo if writable fails.
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

# Normalise CPU arch to the Go-style names release assets use.
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

log() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# install <dest-name> <src-file>  -> move into BIN_DIR, chmod +x
install_bin() { $SUDO install -m 0755 "$2" "${BIN_DIR}/$1"; }

install_kubectl() {
  if have kubectl && [[ "$FORCE" != "1" ]]; then log "kubectl present: $(kubectl version --client -o yaml 2>/dev/null | grep -m1 gitVersion || true)"; return; fi
  local ver="$KUBECTL_VERSION"
  if [[ "$ver" == "stable" ]]; then
    ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  fi
  log "installing kubectl ${ver}"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl"
  install_bin kubectl /tmp/kubectl && rm -f /tmp/kubectl
}

install_helm() {
  if have helm && [[ "$FORCE" != "1" ]]; then log "helm present: $(helm version --short)"; return; fi
  log "installing helm ${HELM_VERSION}"
  curl -fsSLo /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  tar -xzf /tmp/helm.tgz -C /tmp
  install_bin helm "/tmp/${OS}-${ARCH}/helm"
  rm -rf /tmp/helm.tgz "/tmp/${OS}-${ARCH}"
}

install_kind() {
  if have kind && [[ "$FORCE" != "1" ]]; then log "kind present: $(kind version)"; return; fi
  log "installing kind ${KIND_VERSION}"
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
  install_bin kind /tmp/kind && rm -f /tmp/kind
}

install_argocd() {
  if have argocd && [[ "$FORCE" != "1" ]]; then log "argocd present: $(argocd version --client --short 2>/dev/null || true)"; return; fi
  log "installing argocd ${ARGOCD_VERSION}"
  curl -fsSLo /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-${OS}-${ARCH}"
  install_bin argocd /tmp/argocd && rm -f /tmp/argocd
}

install_yq() {
  if have yq && [[ "$FORCE" != "1" ]]; then log "yq present: $(yq --version)"; return; fi
  log "installing yq ${YQ_VERSION}"
  curl -fsSLo /tmp/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
  install_bin yq /tmp/yq && rm -f /tmp/yq
}

# dtctl — Dynatrace platform CLI (github.com/Dynatrace/dtctl). Released by GoReleaser
# as per-OS/arch tarballs: dtctl_<ver>_<os>_<arch>.tar.gz (e.g. dtctl_0.45.0_linux_amd64.tar.gz).
# Source is still pluggable: set DTCTL_DOWNLOAD_URL to a direct .tar.gz (or bare binary)
# for a custom/region mirror, or DTCTL_VERSION to pin a tag. Download failures are
# non-fatal — the rest of the toolchain still installs; tenant wiring is a separate ticket.
install_dtctl() {
  if have dtctl && [[ "$FORCE" != "1" ]]; then log "dtctl present: $(dtctl version 2>/dev/null || echo unknown)"; return; fi
  local url="${DTCTL_DOWNLOAD_URL:-}"
  if [[ -z "$url" ]]; then
    local tag="$DTCTL_VERSION"
    # "latest" has no stable filename (version is embedded in the asset name), so
    # resolve the real tag via the GitHub API before constructing the URL.
    if [[ "$tag" == "latest" ]]; then
      tag="$(curl -fsSL "https://api.github.com/repos/${DTCTL_REPO}/releases/latest" \
             | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
      [[ -z "$tag" ]] && { echo "WARN: could not resolve latest dtctl tag from GitHub API" >&2; return; }
    fi
    local ver="${tag#v}"   # GoReleaser asset names drop the leading v
    url="https://github.com/${DTCTL_REPO}/releases/download/${tag}/dtctl_${ver}_${OS}_${ARCH}.tar.gz"
  fi
  log "installing dtctl from ${url}"
  if ! curl -fsSLo /tmp/dtctl.dl "$url"; then
    echo "WARN: could not download dtctl from ${url}." >&2
    echo "WARN: set DTCTL_DOWNLOAD_URL (direct .tar.gz or binary) or DTCTL_VERSION and re-run:" >&2
    echo "WARN:   FORCE=1 bash .devcontainer/bootstrap/install-tools.sh" >&2
    rm -f /tmp/dtctl.dl
    return
  fi
  # Accept either a gzip tarball (canonical) or a bare binary (custom mirrors).
  if tar tzf /tmp/dtctl.dl >/dev/null 2>&1; then
    local tmpd; tmpd="$(mktemp -d)"
    tar xzf /tmp/dtctl.dl -C "$tmpd"
    local bin; bin="$(find "$tmpd" -type f -name dtctl | head -n1)"
    [[ -z "$bin" ]] && { echo "WARN: dtctl binary not found inside archive" >&2; rm -rf "$tmpd" /tmp/dtctl.dl; return; }
    install_bin dtctl "$bin"
    rm -rf "$tmpd"
  else
    install_bin dtctl /tmp/dtctl.dl
  fi
  rm -f /tmp/dtctl.dl
  log "dtctl installed: $(dtctl version 2>/dev/null || echo 'installed (version check deferred)')"
}

# opencode — the terminal AI coding agent (github.com/sst/opencode) the advanced
# instrumentation lab drives. Released as per-OS/arch tarballs:
# opencode-<os>-<arch>.tar.gz (e.g. opencode-linux-x64.tar.gz), each containing
# the `opencode` binary. The devcontainer base is glibc Ubuntu, so we use the
# non-musl build. Arch-aware via the same $OS/$ARCH the other installers use
# (mapping amd64->x64), and download failures are non-fatal — the rest of the
# toolchain still installs and the workshop can self-heal with FORCE=1 later.
install_opencode() {
  if have opencode && [[ "$FORCE" != "1" ]]; then log "opencode present: $(opencode --version 2>/dev/null || echo unknown)"; return; fi
  # opencode asset arch names: amd64 -> x64, arm64 -> arm64.
  local oc_arch
  case "$ARCH" in
    amd64) oc_arch="x64" ;;
    arm64) oc_arch="arm64" ;;
    *) echo "WARN: no opencode build for arch '$ARCH' — skipping" >&2; return ;;
  esac
  local url="${OPENCODE_DOWNLOAD_URL:-}"
  if [[ -z "$url" ]]; then
    local tag="$OPENCODE_VERSION"
    # "latest" embeds the version in the asset path, so resolve the real tag first.
    if [[ "$tag" == "latest" ]]; then
      tag="$(curl -fsSL "https://api.github.com/repos/${OPENCODE_REPO}/releases/latest" \
             | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
      [[ -z "$tag" ]] && { echo "WARN: could not resolve latest opencode tag from GitHub API" >&2; return; }
    fi
    url="https://github.com/${OPENCODE_REPO}/releases/download/${tag}/opencode-${OS}-${oc_arch}.tar.gz"
  fi
  log "installing opencode from ${url}"
  if ! curl -fsSLo /tmp/opencode.tgz "$url"; then
    echo "WARN: could not download opencode from ${url}." >&2
    echo "WARN: set OPENCODE_DOWNLOAD_URL (direct .tar.gz) or OPENCODE_VERSION and re-run:" >&2
    echo "WARN:   FORCE=1 bash .devcontainer/bootstrap/install-tools.sh" >&2
    rm -f /tmp/opencode.tgz
    return
  fi
  if ! tar tzf /tmp/opencode.tgz >/dev/null 2>&1; then
    echo "WARN: opencode download is not a gzip tarball — skipping" >&2
    rm -f /tmp/opencode.tgz
    return
  fi
  local tmpd; tmpd="$(mktemp -d)"
  tar xzf /tmp/opencode.tgz -C "$tmpd"
  local bin; bin="$(find "$tmpd" -type f -name opencode | head -n1)"
  [[ -z "$bin" ]] && { echo "WARN: opencode binary not found inside archive" >&2; rm -rf "$tmpd" /tmp/opencode.tgz; return; }
  install_bin opencode "$bin"
  rm -rf "$tmpd" /tmp/opencode.tgz
  log "opencode installed: $(opencode --version 2>/dev/null || echo 'installed (version check deferred)')"
}

main() {
  install_kubectl
  install_helm
  install_kind
  install_argocd
  install_yq
  install_dtctl
  install_opencode
  log "toolchain install complete"
}
main "$@"
