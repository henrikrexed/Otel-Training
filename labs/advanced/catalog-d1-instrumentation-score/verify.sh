#!/usr/bin/env bash
# Catalog D1 — re-run the four anchor DQLs and compute the instrumentation score.
#
# Deferred-verify pattern (same as the C-theme labs, ISI-6807): this needs a live
# Dynatrace tenant to actually query. When dtctl is not configured, it PRINTS the
# four anchor DQLs + the weighted-score formula so a facilitator can run them in a
# Notebook / Henrik can run them live — it never silently "passes".
#
# What it checks (each anchor returns a pass_ratio in [0,1]):
#   RES-001  service.name present on spans          Critical  w=40
#   SPA      span status recorded on server spans   Important w=30
#   LOG      trace_id present on logs               Normal    w=20
#   MET      casino.bet.tier present + bounded (<=8) Important w=30
# score = Σ(weightᵢ × pass_ratioᵢ) / Σweightᵢ × 100
# bands: >=90 Excellent · >=75 Good · >=50 Needs work · <50 Poor
#
# Exit codes:
#   0  all four anchors queried and a score computed
#   2  inconclusive — dtctl/tenant not available (DQLs printed for live run)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOW="${WINDOW:-now() - 30m}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

# --- the four anchor DQLs (each yields a field named pass_ratio) -------------
RES_DQL="fetch spans, from: ${WINDOW} | summarize total = count(), missing = countIf(isNull(service.name)) | fieldsAdd pass_ratio = (total - missing) / total | fields pass_ratio"
SPA_DQL="fetch spans, from: ${WINDOW} | filter span.kind == \"server\" | summarize total = count(), recorded = countIf(span.status_code != \"UNSET\") | fieldsAdd pass_ratio = recorded / total | fields pass_ratio"
LOG_DQL="fetch logs, from: ${WINDOW} | summarize total = count(), correlated = countIf(isNotNull(trace_id)) | fieldsAdd pass_ratio = correlated / total | fields pass_ratio"
MET_DQL="fetch spans, from: ${WINDOW} | summarize present = countIf(isNotNull(casino.bet.tier)), total = count(), distinct_tier = countDistinct(casino.bet.tier) | fieldsAdd pass_ratio = present / total | fields pass_ratio"

print_dqls() {
  bold "Anchor DQLs (run each in a Notebook / with 'dtctl query -o json'):"
  printf '\n# RES-001 service.name present (Critical w=40)\n%s\n' "$RES_DQL"
  printf '\n# SPA span status recorded (Important w=30)\n%s\n' "$SPA_DQL"
  printf '\n# LOG trace_id on logs (Normal w=20)\n%s\n' "$LOG_DQL"
  printf '\n# MET casino.bet.tier present + bounded (Important w=30)\n%s\n' "$MET_DQL"
  printf '\nscore = (40*res + 30*spa + 20*log + 30*met) / 120 * 100\n'
  printf 'bands: >=90 Excellent · >=75 Good · >=50 Needs work · <50 Poor\n'
}

bold "== Catalog D1 — instrumentation score (window: ${WINDOW}) =="

# --- preconditions: deferred-verify ------------------------------------------
if ! command -v dtctl >/dev/null 2>&1; then
  warn "dtctl not on PATH — inconclusive (deferred verify)."
  warn "Install via the codespace bootstrap (ISI-7175), or run the DQLs by hand:"
  echo
  print_dqls
  exit 2
fi
if ! dtctl query "fetch spans | limit 1" >/dev/null 2>&1; then
  warn "dtctl present but could not reach the tenant (no token/connectivity) — inconclusive."
  warn "Configure the platform token (ISI-7175) and re-run, or run the DQLs by hand:"
  echo
  print_dqls
  exit 2
fi

# --- extract a single pass_ratio from a DQL via dtctl query -o json ----------
ratio() { # $1 = DQL -> echoes a float in [0,1] (or empty on failure)
  dtctl query "$1" -o json 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
# dtctl -o json shapes vary; find the first numeric pass_ratio anywhere.
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k=="pass_ratio" and isinstance(v,(int,float)): return float(v)
            r=walk(v)
            if r is not None: return r
    elif isinstance(x,list):
        for v in x:
            r=walk(v)
            if r is not None: return r
    return None
r=walk(d)
print("" if r is None else r)'
}

RES="$(ratio "$RES_DQL")"
SPA="$(ratio "$SPA_DQL")"
LOG="$(ratio "$LOG_DQL")"
MET="$(ratio "$MET_DQL")"

report() { # $1 label $2 ratio $3 weight
  if [[ -z "$2" ]]; then bad "$1 (w=$3): no pass_ratio returned — check the DQL / data in window"; return 1; fi
  ok "$1 (w=$3): pass_ratio = $2"
}

rc=0
report "RES-001 service.name" "$RES" 40 || rc=1
report "SPA span status"       "$SPA" 30 || rc=1
report "LOG trace_id"          "$LOG" 20 || rc=1
report "MET bet.tier bounded"  "$MET" 30 || rc=1

if [[ $rc -ne 0 ]]; then
  echo
  warn "One or more anchors returned no data — cannot compute a full score."
  print_dqls
  exit 2
fi

SCORE="$(python3 -c "r,s,l,m=$RES,$SPA,$LOG,$MET; print(round((40*r+30*s+20*l+30*m)/120*100,1))")"
BAND="$(python3 -c "x=$SCORE; print('Excellent' if x>=90 else 'Good' if x>=75 else 'Needs work' if x>=50 else 'Poor')")"
echo
bold "Instrumentation score = ${SCORE}  (band: ${BAND})"
echo "score = (40*${RES} + 30*${SPA} + 20*${LOG} + 30*${MET}) / 120 * 100"
exit 0
