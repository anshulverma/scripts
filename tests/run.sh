#!/usr/bin/env bash
# Usage: bash tests/run.sh [substring]   (substring matches a test file name or a t_* name)
here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=/dev/null
. "$here/lib.sh"
log=$(mktemp); failed=0; ran=0
for f in "$here"/test_*.sh; do
  # shellcheck source=/dev/null
  . "$f"
  # shellcheck disable=SC2013
  for t in $(grep -o '^t_[A-Za-z0-9_]*' "$f"); do
    case $f/$t in *"${1:-}"*) ;; *) continue;; esac
    ran=$((ran + 1))
    if ( setup_env; "$t" ) >"$log" 2>&1; then
      echo "PASS $t"
    else
      echo "FAIL $t: $(tr '\n' ' ' <"$log")"; failed=1
    fi
  done
done
rm -f "$log"
[ "$ran" -gt 0 ] || { echo "no tests matched '${1:-}'" >&2; exit 1; }
exit "$failed"
