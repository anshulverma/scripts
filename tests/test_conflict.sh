#!/usr/bin/env bash
TAB=$(printf '\t')
head_of() { git -C "$WS/$1" rev-parse HEAD; }
# make_minbin [TOOL...]: $T/minbin with symlinks to only what reposync needs (+ TOOLs); no claude, no timeout.
make_minbin() {
  local t p
  mkdir -p "$T/minbin"
  for t in bash env sh git mktemp cat rm mkdir date od awk sort tr head grep mv cksum "$@"; do
    p=$(type -P "$t") || fail "make_minbin: $t not found"
    ln -s "$p" "$T/minbin/$t"
  done
}
# conflict_run MODE: make_conflict a, run reposync with the stub in MODE; sets P (pre-run HEAD) and RT (remote tip).
conflict_run() {
  make_conflict a
  P=$(head_of a) RT=$(remote_head a)
  STUB_CLAUDE_MODE=$1 run_reposync
}
# assert_restored [RC]: failure post-conditions for repo a: rc (default 1), HEAD == P, no MERGE_HEAD, clean status, remote == RT.
assert_restored() {
  local n=a
  assert_rc "${1:-1}"
  assert_eq "$P" "$(head_of "$n")" HEAD
  git -C "$WS/$n" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "MERGE_HEAD left"
  assert_eq "" "$(git -C "$WS/$n" status --porcelain)" status
  assert_eq "$RT" "$(remote_head "$n")" remote
}
# minpath CMD: `command -v` output under PATH=$T/minbin.
minpath() { env PATH="$T/minbin" sh -c 'command -v "$@"' _ "$@"; }
# result [NAME]: the result column of NAME's row.
result() { row "${1:-a}" | cut -f4; }

t_resolve_ok() {
  conflict_run resolve; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged+pushed${TAB}ok" "$(row a)" row
  assert_eq "$(head_of a) $P $RT" "$(git -C "$WS/a" rev-list --parents -n1 HEAD)" parents
  assert_eq "$(head_of a)" "$(remote_head a)" remote
  local log; log=$(cat "$STUB_CLAUDE_LOG")
  assert_contains "$log" README
  assert_contains "$log" "You are resolving a merge of origin/main (theirs, remote) into local main (ours)"
  assert_contains "$log" "Do not run any of these git commands:"
}
t_leave_markers() { conflict_run leave-markers; assert_restored; assert_eq failed:merge-conflict-unresolved "$(result)" result; }
t_exit1() { conflict_run exit-1; assert_restored; assert_eq "failed:claude (rc=1)" "$(result)" result; }
t_timeout() {
  make_conflict a; P=$(head_of a) RT=$(remote_head a)
  REPOSYNC_CLAUDE_TIMEOUT=2 STUB_CLAUDE_MODE=sleep start_reposync_bg
  wait_bg 40
  assert_restored; assert_eq failed:claude-timeout "$(result)" result
}
t_claude_commits() {
  conflict_run commit; assert_restored; assert_eq "failed:claude-modified-git-state: HEAD" "$(result)" result
}
t_claude_reset_hard() {
  conflict_run reset-hard; assert_restored
  case $(result) in failed:claude-modified-git-state:*) ;; *) fail "result: $(result)";; esac
  [ "$(git -C "$WS/a" log -1 --format=%s main)" = "local README" ] || fail "local commit lost"
}
t_claude_untracked() {
  conflict_run untracked; assert_restored
  case $(result) in failed:*) ;; *) fail "result: $(result)";; esac
  [ -e "$WS/a/stray.txt" ] && fail "stray.txt left in repo"
  [ -n "$(find "$HOME/.local/state/reposync/rescue/a" -name stray.txt)" ] || fail "stray.txt not rescued"
}
t_user_file_rescued() {
  conflict_run user-file; assert_restored
  case $(result) in failed:*) ;; *) fail "result: $(result)";; esac
  local f; f=$(find "$HOME/.local/state/reposync/rescue/a" -name notes.md)
  assert_eq notes "$(cat "$f")" "rescued notes.md"
}
t_claude_checkout_other() {
  make_conflict a; git -C "$WS/a" branch other HEAD~1
  local x; x=$(git -C "$WS/a" rev-parse other)
  P=$(head_of a) RT=$(remote_head a)
  STUB_CLAUDE_MODE=checkout-other run_reposync; assert_restored
  case $(result) in failed:*) ;; *) fail "result: $(result)";; esac
  assert_eq refs/heads/main "$(git -C "$WS/a" symbolic-ref HEAD)" branch
  assert_eq "$x" "$(git -C "$WS/a" rev-parse other)" "other moved"
}
t_setext_heading() {
  make_conflict a "remote
Title
======="
  STUB_CLAUDE_MODE=resolve run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged+pushed${TAB}ok" "$(row a)" row
  grep -qx '=======' "$WS/a/README" || fail "setext underline dropped: $(cat "$WS/a/README")"
  git -C "$WS/a" diff HEAD^1 HEAD -- README | grep -qx '+=======' || fail "first-parent diff lacks +======="
}
t_zdiff3_base_marker_left() {
  conflict_run base-marker; assert_restored; assert_eq failed:merge-conflict-unresolved "$(result)" result
}
t_space_path_conflict() {
  make_conflict a "" "a b.txt" "ü.txt"
  STUB_CLAUDE_MODE=resolve run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged+pushed${TAB}ok" "$(row a)" row
  assert_contains "$(cat "$STUB_CLAUDE_LOG")" "UU a b.txt"
  assert_contains "$(cat "$STUB_CLAUDE_LOG")" "UU ü.txt"
  assert_eq "local" "$(head -n 1 "$WS/a/ü.txt")" "ü.txt resolved"
  assert_eq "" "$(git -C "$WS/a" status --porcelain)" status
}
t_three_repos_first_conflicts() {
  make_conflict a; make_repo b; local_commit b f x; make_repo c; remote_commit c g y
  STUB_CLAUDE_MODE=exit-1 run_reposync; assert_rc 1
  assert_eq "failed:claude (rc=1)" "$(result a)" "a"
  assert_eq "b${TAB}main${TAB}pushed${TAB}ok" "$(row b)" b
  assert_eq "c${TAB}main${TAB}merged${TAB}ok" "$(row c)" c
}
t_no_claude() {
  make_conflict a; P=$(head_of a) RT=$(remote_head a); make_minbin timeout
  [ -z "$(minpath claude)" ] || fail "claude reachable in minbin"
  PATH=$T/minbin run_reposync; assert_restored
  assert_eq failed:claude-unavailable "$(result)" result
}
t_no_timeout_bin() {
  make_conflict a; P=$(head_of a) RT=$(remote_head a); make_minbin
  ln -s "$TESTS/stubs/claude" "$T/minbin/claude"
  assert_eq "$T/minbin/claude" "$(minpath claude)" "stub in minbin"
  [ -z "$(minpath timeout gtimeout)" ] || fail "timeout reachable in minbin"
  STUB_CLAUDE_MODE=resolve PATH=$T/minbin run_reposync; assert_restored
  assert_eq failed:claude-unavailable "$(result)" result
  [ -s "$STUB_CLAUDE_LOG" ] && fail "claude called without timeout"
  true
}
t_sigterm() {
  make_conflict a; P=$(head_of a) RT=$(remote_head a)
  REPOSYNC_CLAUDE_TIMEOUT=600 STUB_CLAUDE_MODE=sleep STUB_MARKER=$T/m start_reposync_bg
  local i=0
  while [ ! -e "$T/m" ]; do
    [ "$i" -ge 100 ] && { kill -KILL "$BGPID"; fail "stub never started"; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$BGPID"
  wait_bg 15; assert_restored 143
  assert_eq failed:interrupted "$(result)" result
  kill -0 "$(cat "$T/stub.pid")" 2>/dev/null && fail "stub still alive"
  true
}
t_claude_cwd() {
  conflict_run pwd
  assert_eq "$(cd -P "$WS/a" && pwd)" "$(cat "$T/stub.cwd")" cwd
}
t_claude_edits_other() {
  conflict_run edit-other; assert_restored
  case $(result) in failed:claude-modified-git-state*) ;; *) fail "result: $(result)";; esac
  assert_eq other "$(cat "$WS/a/other.txt")" other.txt
}
t_claude_stages() {
  conflict_run stage; assert_restored
  case $(result) in failed:claude-modified-git-state*) ;; *) fail "result: $(result)";; esac
}
t_push_blocked_for_child() {
  conflict_run push-leak; assert_restored
  assert_eq "a${TAB}main${TAB}none${TAB}failed:claude (rc=1)" "$(row a)" row
  git --git-dir="$REMOTES/a.git" rev-parse -q --verify refs/heads/leak >/dev/null && fail "leak pushed"
  assert_contains "$(cat "$T/leak.err")" "transport 'file' not allowed"
}
