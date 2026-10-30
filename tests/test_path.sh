#!/usr/bin/env bash
# Unit tests for the pure version helpers in gitlab-upgrade.sh. No root, no GitLab needed.
#   bash tests/test_path.sh
set -uo pipefail

export GUK_SOURCED=1
GUK_STATE_DIR="$(mktemp -d)"; export GUK_STATE_DIR
trap 'rm -r -- "$GUK_STATE_DIR"' EXIT
# shellcheck source=gitlab-upgrade.sh source-path=SCRIPTDIR/..
source "$(dirname "$0")/../gitlab-upgrade.sh"
set +e

pass=0 fail=0
check() {  # check NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$1" "$2" "$3"; fi
}
path_of() { printf '%s\n' "${VERSIONS[@]}" | compute_path "$1" "$2" | paste -sd' ' -; }

VERSIONS=(
  18.4.1 18.4.6 18.5.0 18.5.7 18.6.3 18.8.0 18.8.11 18.9.2 18.10.5
  18.11.11 18.11.12 19.0.4 19.1.6 19.2.7 19.2.10 19.3.7 19.4.1 19.4.5 19.5.0 19.5.3
)

echo "compute_path"
check "multi-hop within a major"          "18.5.7 18.8.11 18.11.12"        "$(path_of 18.4.1 18.11.12)"
check "single next stop"                   "19.5.3"                          "$(path_of 19.4.1 19.5.3)"
check "patch-first, across a major"        "18.11.12 19.2.10 19.4.5"         "$(path_of 18.11.11 19.4.5)"
check "already on target"                  ""                                "$(path_of 19.5.3 19.5.3)"
check "target older than current"          ""                                "$(path_of 19.5.3 19.4.1)"
check "patch-only upgrade inside a minor"  "19.4.5"                          "$(path_of 19.4.1 19.4.5)"
check "on latest patch of a stop"          "19.2.10 19.4.5"                  "$(path_of 18.11.12 19.4.5)"
check "multi-digit minors sort correctly"  "18.8.11 18.11.12"                "$(path_of 18.6.3 18.11.12)"
GUK_EXTRA_STOPS_SAVED="$EXTRA_STOPS"
EXTRA_STOPS="19.0"
check "extra stop via GUK_EXTRA_STOPS"     "18.11.12 19.0.4 19.2.10 19.5.3"  "$(path_of 18.11.11 19.5.3)"
EXTRA_STOPS="$GUK_EXTRA_STOPS_SAVED"

echo "resolve_target"
list() { printf '%s\n' "${VERSIONS[@]}"; }
check "latest"         "19.5.3"  "$(list | resolve_target latest)"
check "minor"          "18.8.11" "$(list | resolve_target 18.8)"
check "exact present"  "19.4.1"  "$(list | resolve_target 19.4.1)"
check "exact missing"  ""        "$(list | resolve_target 19.4.2)"
check "garbage"        ""        "$(list | resolve_target banana)"

echo "helpers"
check "ver_base strips package suffix" "19.5.3" "$(ver_base 19.5.3-ce.0)"
check "minor_of"                       "18.11"  "$(minor_of 18.11.12)"
ver_lt 18.9.0 18.10.0; check "ver_lt is version-aware" "0" "$?"
ver_lt 19.5.3 19.5.3;  check "ver_lt is strict"        "1" "$?"

echo "human_gate"
current_ver() { echo 19.5.3; }
ASSUME_YES=true
( human_gate snapshot "text" >/dev/null 2>&1 ); check "--yes without env waits (exit 2)" "2" "$?"
check "no marker while waiting" "no" "$([[ -e "$STATE_DIR/gate-snapshot-19.5.3" ]] && echo yes || echo no)"
( GUK_CONFIRM_SNAPSHOT=yes human_gate snapshot "text" >/dev/null 2>&1 ); check "env confirms" "0" "$?"
check "marker recorded per version" "yes" "$([[ -f "$STATE_DIR/gate-snapshot-19.5.3" ]] && echo yes || echo no)"
( human_gate snapshot "text" >/dev/null 2>&1 ); check "second call passes via marker" "0" "$?"
current_ver() { echo 19.8.1; }
( human_gate snapshot "text" >/dev/null 2>&1 ); check "new version asks again" "2" "$?"
ASSUME_YES=false

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
