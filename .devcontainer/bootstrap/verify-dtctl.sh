#!/usr/bin/env bash
# verify-dtctl.sh — prove the Dynatrace platform CLI is installed and runnable
# in the attendee codespace (ISI-7175, ISI-7169·B1).
#
# install-tools.sh installs dtctl, but its download is deliberately NON-fatal
# (a region/network hiccup must not break the rest of the toolchain). That means
# an attendee could silently end up WITHOUT dtctl and only discover it later when
# the Dynatrace-for-AI skills (B2/B3) that depend on the CLI fail. This check
# surfaces that immediately, right after bootstrap, as a first-class gate.
#
# It is intentionally small and cluster-independent (dtctl is a local CLI): it
# only proves the binary is on PATH and that `dtctl version` exits cleanly.
#
# Exit codes:
#   0  dtctl present and `dtctl version` succeeded
#   1  dtctl missing from PATH, or `dtctl version` failed
#
# Version drift (installed != pinned) is a WARNING, not a failure — a custom
# DTCTL_DOWNLOAD_URL / DTCTL_VERSION=latest is a supported override.
set -uo pipefail

# Pinned reference — keep in sync with install-tools.sh / verify-arch.sh.
DTCTL_VERSION="${DTCTL_VERSION:-v0.45.0}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

bold "== dtctl verify (pinned ${DTCTL_VERSION}) =="

# 1. Is it on PATH at all?
path="$(command -v dtctl 2>/dev/null || true)"
if [[ -z "$path" ]]; then
  bad "dtctl is NOT on PATH"
  cat >&2 <<EOF

The Dynatrace CLI did not install. The download in install-tools.sh is non-fatal,
so bootstrap continued without it. Re-install (honours TARGETARCH/uname + the pin):

  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh

Behind a proxy / in an air-gapped region, point it at a reachable asset:

  DTCTL_DOWNLOAD_URL=<direct .tar.gz or binary> FORCE=1 \\
    bash .devcontainer/bootstrap/install-tools.sh

The Dynatrace-for-AI skills (ISI-7169 B2/B3) need this CLI present.
EOF
  exit 1
fi
ok "dtctl on PATH: ${path}"

# 2. Does `dtctl version` actually run? (the real AC)
if ! ver_out="$(dtctl version 2>&1)"; then
  bad "'dtctl version' failed to execute:"
  printf '%s\n' "$ver_out" >&2
  exit 1
fi
ok "'dtctl version' succeeded"
printf '      %s\n' "$ver_out"

# 3. Soft version-drift check (warn only).
want="${DTCTL_VERSION#v}"
if printf '%s' "$ver_out" | grep -q -- "$want"; then
  ok "reported version matches pin (${DTCTL_VERSION})"
else
  warn "reported version does not contain the pin '${want}' — override or drift (non-fatal)"
fi

bold "RESULT: dtctl OK"
exit 0
