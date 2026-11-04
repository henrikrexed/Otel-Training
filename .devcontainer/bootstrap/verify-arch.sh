#!/usr/bin/env bash
# verify-arch.sh — prove the toolchain is the right CPU arch for this host.
#
# Background (ISI-7044 / ISI-7049): `kind` segfaulted on Apple Silicon because the
# devcontainer resolved to an *emulated amd64* image — kind then ran amd64 node
# containers under QEMU, which crashes. The arch logic in install-tools.sh is
# correct; this script is the smallest proof that it produced host-native binaries
# and a tripwire for the emulated-amd64 trap.
#
# It does three things:
#   1. Prints the resolved download URL for EVERY tool, for BOTH arches, so you can
#      eyeball that the detector would fetch the right asset on either platform.
#   2. Reports the actual ELF machine type of each INSTALLED binary (no `file`
#      dependency — reads the ELF header directly).
#   3. Flags a mismatch between the installed binary arch and this host's native
#      arch (the emulated-amd64 fingerprint).
#
# Exit non-zero only on a real arch mismatch, so it is usable as a CI/preflight gate.
set -euo pipefail

# --- versions (keep in sync with install-tools.sh) ---------------------------
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.31.2}"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"
KIND_VERSION="${KIND_VERSION:-v0.25.0}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.2}"
YQ_VERSION="${YQ_VERSION:-v4.44.6}"
DTCTL_VERSION="${DTCTL_VERSION:-v0.45.0}"
DTCTL_REPO="${DTCTL_REPO:-Dynatrace/dtctl}"

# --- host arch (same precedence as install-tools.sh) -------------------------
raw_arch="${TARGETARCH:-$(uname -m)}"
case "$raw_arch" in
  x86_64|amd64)   HOST_ARCH="amd64" ;;
  aarch64|arm64)  HOST_ARCH="arm64" ;;
  *) echo "unsupported arch: $raw_arch" >&2; exit 1 ;;
esac
OS="${TARGETOS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# urls_for <os> <arch> — echo the download URL the installer would use per tool.
urls_for() {
  local os="$1" arch="$2" dtver="${DTCTL_VERSION#v}"
  echo "  kubectl : https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl"
  echo "  helm    : https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz"
  echo "  kind    : https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
  echo "  argocd  : https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-${os}-${arch}"
  echo "  yq      : https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${os}_${arch}"
  echo "  dtctl   : https://github.com/${DTCTL_REPO}/releases/download/${DTCTL_VERSION}/dtctl_${dtver}_${os}_${arch}.tar.gz"
}

# elf_arch <path> — print amd64 | arm64 | other<n> | <error> for an ELF binary.
# Reads the ELF e_machine field (2 bytes little-endian at offset 18) without `file`.
elf_arch() {
  local f="$1"
  [[ -r "$f" ]] || { echo "unreadable"; return; }
  # Confirm ELF magic (0x7f 'E' 'L' 'F').
  local magic; magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' ')"
  [[ "$magic" == "7f454c46" ]] || { echo "not-elf"; return; }
  # e_machine: 2 bytes at offset 18, little-endian on the little-endian builds we ship.
  local m; m="$(od -An -tu2 -j18 -N2 "$f" 2>/dev/null | tr -d ' ')"
  case "$m" in
    62)  echo "amd64" ;;   # EM_X86_64
    183) echo "arm64" ;;   # EM_AARCH64
    *)   echo "other(${m})" ;;
  esac
}

bold "== host =="
echo "  uname -s/-m : $(uname -s)/$(uname -m)"
echo "  TARGETARCH  : ${TARGETARCH:-<unset>}   TARGETOS: ${TARGETOS:-<unset>}"
echo "  resolved    : ${OS}/${HOST_ARCH}"
echo

bold "== resolved download URLs (both arches — proof the detector is arch-parametric) =="
echo "linux/amd64:"; urls_for linux amd64
echo "linux/arm64:"; urls_for linux arm64
echo "darwin/arm64 (host-native Mac tooling, if ever installed outside the container):"
urls_for darwin arm64
echo

bold "== installed binary arch vs host (${HOST_ARCH}) =="
rc=0
for tool in kubectl helm kind argocd yq dtctl; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    printf "  %-8s not installed\n" "$tool"
    continue
  fi
  a="$(elf_arch "$path")"
  if [[ "$a" == "$HOST_ARCH" ]]; then
    printf "  %-8s %-6s OK   (%s)\n" "$tool" "$a" "$path"
  else
    printf "  %-8s %-6s MISMATCH — expected %s  (%s)\n" "$tool" "$a" "$HOST_ARCH" "$path"
    rc=1
  fi
done
echo

if [[ $rc -ne 0 ]]; then
  bold "RESULT: ARCH MISMATCH"
  cat <<'EOF'
One or more binaries do not match this host's architecture. On an Apple Silicon
Mac this is the ISI-7044 segfault trap: the devcontainer was built/pulled as
linux/amd64 and is running under QEMU emulation, so kind will crash.

Fix:
  * Build the devcontainer NATIVELY. Do NOT pass --platform=linux/amd64.
  * Remove stale amd64 images and rebuild:
      docker rmi <the devcontainer image>        # or: Dev Containers: Rebuild Without Cache
  * Check Docker Desktop is not forcing a default amd64 platform
    (Settings → General → "Use Rosetta…"/default platform).
  * Re-heal the toolchain inside the container:
      FORCE=1 bash .devcontainer/bootstrap/install-tools.sh
EOF
else
  bold "RESULT: all installed binaries match host arch (${HOST_ARCH})"
fi

cat <<'EOF'

----------------------------------------------------------------------
Human-gated step (only one): runtime verification on an Apple Silicon Mac.
A matching arch above proves the *binaries* are native. The final proof that
the QEMU segfault is gone is to actually create the cluster on an M-series Mac:

  bash .devcontainer/bootstrap/create-cluster.sh
  kubectl get nodes          # control-plane Ready, no segfault

GitHub Codespaces runs on amd64 cloud VMs, so attendees never hit this path —
it only affects a devcontainer built locally on Apple Silicon.
----------------------------------------------------------------------
EOF
exit $rc
