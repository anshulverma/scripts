#!/usr/bin/env bash
TAB=$(printf '\t')
LOG=report.log
logf() { cat "$HOME/.local/state/reposync/$LOG"; }

t_report_log() {
  make_repo a; make_repo b; local_commit a f x; git -C "$WS/b" remote set-url origin file:///nonexistent.git
  run_reposync; assert_rc 1
  local l; l=$(logf)
  assert_contains "$l" "reposync "
  assert_contains "$l" "workspace=$WS dirty=skip"
  assert_contains "$l" "a${TAB}main${TAB}pushed${TAB}ok"
  assert_contains "$l" "b${TAB}main${TAB}none${TAB}failed:fetch
  "
  assert_contains "$l" nonexistent
  assert_contains "$l" "summary: 2 repos: 1 ok, 0 skipped, 1 failed, 0 warnings;"
  assert_contains "$l" "exit 1"
  # the report also ends stderr; stdout stays rows only
  assert_contains "$(printf '%s\n' "$ERR" | tail -n 1)" "summary: 2 repos: 1 ok, 0 skipped, 1 failed"
  assert_eq 2 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "stdout rows"
  # appended, not overwritten
  run_reposync --dry-run
  assert_eq 2 "$(logf | grep -c '^summary: ')" "two runs logged"
  assert_contains "$(logf | grep '^reposync ' | tail -n 1)" "dirty=skip dry-run"
}
t_report_tail_per_repo() {
  # a's long fetch error must not show under b; claude's stderr has no final newline; a successful fetch adds nothing.
  make_repo a; make_conflict b; make_repo c
  git -C "$WS/a" remote set-url origin file:///nonexistent.git
  STUB_CLAUDE_MODE=stderr-no-nl run_reposync; assert_rc 1
  local blk; blk=$(logf | awk '/^b\t/ { p = 1; print; next } p && /^  / { print; next } { p = 0 }')
  assert_contains "$blk" "b${TAB}main${TAB}none${TAB}failed:claude (rc=1)"
  case $blk in *"repository exists"*|*nonexistent*|*"From file://"*) fail "foreign lines under b: $blk";; esac
  assert_contains "$(logf)" "  boom
c${TAB}main${TAB}none${TAB}ok"
}
t_report_closed_stderr() {
  make_repo a
  ( (cd "$T" && sleep 0.5; "$REPOSYNC" --workspace "$WS" >/dev/null; echo $? >"$T/rc") 2>&1 | true )
  assert_eq 0 "$(cat "$T/rc")" rc
  assert_contains "$(logf)" "summary: 1 repos: 1 ok"
  [ ! -d "$HOME/.local/state/reposync/lock" ] || fail "lock left behind"
}
t_report_skip_warn() {
  make_repo a; mkdir "$WS/plain"; echo u >"$WS/a/u"
  git -C "$WS/a" stash push -q -u -m "reposync-keep 2026-01-01T00:00:00Z"; echo u >"$WS/a/u"
  run_reposync; assert_rc 1
  assert_contains "$(logf)" "WARN a: leftover reposync stash"
  assert_contains "$(logf)" "summary: 2 repos: 0 ok, 2 skipped, 0 failed, 1 warnings;"
}
t_report_lock_held() {
  sleep 30 & local p=$!
  mkdir -p "$HOME/.local/state/reposync/lock"; echo $p >"$HOME/.local/state/reposync/lock/pid"
  run_reposync; assert_rc 3; kill $p
  assert_contains "$(logf)" "error: another run (pid $p) holds the lock"
  assert_contains "$(logf)" "summary: 0 repos: 0 ok, 0 skipped, 0 failed, 0 warnings;"
  assert_contains "$(logf)" "exit 3"
}
t_report_bad_workspace() {
  bin_reposync --workspace "$T/nope"; assert_rc 2
  assert_contains "$(logf)" "error: workspace not found: $T/nope"
}
t_report_none_on_usage() {
  run_reposync --help; run_reposync --bogus
  [ -e "$HOME/.local/state/reposync/$LOG" ] && fail "report written for --help/usage error"
  true
}
t_report_trim() {
  mkdir -p "$HOME/.local/state/reposync"; seq 1 6000 >"$HOME/.local/state/reposync/$LOG"
  make_repo a; run_reposync; assert_rc 0
  assert_eq 5000 "$(logf | wc -l | tr -d ' ')" lines
  assert_contains "$(logf | tail -n 4)" "summary: 1 repos: 1 ok"
}
t_report_sigterm() {
  make_conflict a; local i=0
  REPOSYNC_CLAUDE_TIMEOUT=600 STUB_CLAUDE_MODE=sleep STUB_MARKER=$T/m start_reposync_bg
  while [ ! -e "$T/m" ]; do
    [ "$i" -ge 100 ] && { kill -KILL "$BGPID"; fail "stub never started"; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$BGPID"
  wait_bg 15; assert_rc 143
  assert_contains "$(logf)" "a${TAB}main${TAB}none${TAB}failed:interrupted"
  assert_contains "$(logf)" "summary: 1 repos: 0 ok, 0 skipped, 1 failed, 0 warnings;"
  assert_contains "$(logf)" "exit 143"
}
