#!/usr/bin/env bash
# --dirty=commit and --dirty=keep (§7.3, §7.6 step 4, §8.2, §8.3). Uses TAB head_of make_minbin minpath result
# from test_conflict.sh (sourced earlier by run.sh).
FALLBACK_RE='^reposync: auto-commit from .+ at [0-9T:-]+Z$'
# wt: repo a's uncommitted state (unstaged, staged, untracked) for byte comparison.
wt() {
  local d=$WS/a
  git -C "$d" diff; echo @@; git -C "$d" diff --cached; echo @@; git -C "$d" ls-files --others --exclude-standard
}
subject() { git -C "$WS/a" log -1 --format=%s; }
# keeps: reposync-keep stash entries of repo a.
keeps() { git -C "$WS/a" stash list --format='%H %s' | grep 'reposync-keep '; }
# stashed_sha: the sha reposync reported as stashed (from ERR).
stashed_sha() { printf '%s\n' "$ERR" | awk '/stashed local changes: /{ print $NF; exit }'; }
exit1_hook() { printf '#!/bin/sh\nexit 1\n' >"$1" && chmod +x "$1"; }

t_commit_ahead() {
  make_repo a; echo changed >"$WS/a/README"; echo new >"$WS/a/new.txt"
  run_reposync --dirty=commit; assert_rc 0
  assert_eq "a${TAB}main${TAB}committed+pushed${TAB}ok" "$(row a)" row
  assert_eq "stub: commit message" "$(subject)" subject
  assert_eq "$(head_of a)" "$(remote_head a)" remote
  assert_eq "" "$(git -C "$WS/a" status --porcelain)" status
}
t_commit_msg_fallback() {
  make_repo a; echo changed >"$WS/a/README"
  STUB_MSG_MODE=fail run_reposync --dirty=commit; assert_rc 0
  subject | grep -Eq "$FALLBACK_RE" || fail "subject: $(subject)"
}
t_commit_msg_fenced() {
  make_repo a; echo changed >"$WS/a/README"
  STUB_MSG=$'```\nfix: x\n```' run_reposync --dirty=commit; assert_rc 0
  assert_eq "fix: x" "$(git -C "$WS/a" log -1 --format=%B)" message
}
t_commit_msg_too_long() {
  make_repo a; echo changed >"$WS/a/README"
  STUB_MSG=$(printf '%080d' 0) run_reposync --dirty=commit; assert_rc 0
  subject | grep -Eq "$FALLBACK_RE" || fail "subject: $(subject)"
}
t_commit_hook_fails() {
  make_repo a; echo s >"$WS/a/s.txt"; git -C "$WS/a" add s.txt; echo u >>"$WS/a/README"
  exit1_hook "$WS/a/.git/hooks/pre-commit"
  local p before; p=$(head_of a); before=$(wt)
  run_reposync --dirty=commit; assert_rc 1
  assert_eq "a${TAB}main${TAB}none${TAB}failed:commit" "$(row a)" row
  assert_eq "$before" "$(wt)" "uncommitted state"
  assert_eq "$p" "$(head_of a)" HEAD
}
t_commit_behind() {
  make_repo a; remote_commit a r.txt x; echo changed >"$WS/a/README"
  run_reposync --dirty=commit; assert_rc 0
  assert_eq "a${TAB}main${TAB}committed+merged+pushed${TAB}ok" "$(row a)" row
  assert_eq "$(head_of a)" "$(remote_head a)" remote
}
t_commit_msg_no_timeout() {
  make_repo a; echo changed >"$WS/a/README"; make_minbin
  ln -s "$TESTS/stubs/claude" "$T/minbin/claude"
  [ -z "$(minpath timeout gtimeout)" ] || fail "timeout reachable in minbin"
  PATH=$T/minbin run_reposync --dirty=commit; assert_rc 0
  subject | grep -Eq "$FALLBACK_RE" || fail "subject: $(subject)"
  [ -s "$STUB_CLAUDE_LOG" ] && fail "claude called without timeout"
  true
}
t_commit_huge_diff() {
  make_repo a; seq 1 2500 >"$WS/a/big.txt"
  run_reposync --dirty=commit; assert_rc 0
  assert_eq "a${TAB}main${TAB}committed+pushed${TAB}ok" "$(row a)" row
  assert_contains "$(cat "$STUB_CLAUDE_LOG")" "1 file changed, 2500 insertions(+)"
  [ "$(wc -l <"$STUB_CLAUDE_LOG")" -le 600 ] || fail "prompt has $(wc -l <"$STUB_CLAUDE_LOG") lines"
  grep -qx '+1' "$STUB_CLAUDE_LOG" || fail "diff start missing"
  grep -qx '+2500' "$STUB_CLAUDE_LOG" && fail "diff not truncated"
  assert_eq 2500 "$(git -C "$WS/a" show HEAD:big.txt | wc -l | tr -d ' ')" "committed lines"
}
t_keep_nonoverlap() {
  make_repo a
  (cd "$WS/a" && echo A >A && echo B >B && git add A B && git commit -qm ab \
    && git push -q origin HEAD:refs/heads/main 2>/dev/null) || fail setup
  echo A2 >>"$WS/a/A"; git -C "$WS/a" add A; echo B2 >>"$WS/a/B"; echo C >"$WS/a/C"
  remote_commit a D d
  local before; before=$(wt)
  run_reposync --dirty=keep; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged${TAB}ok" "$(row a)" row
  assert_eq "$before" "$(wt)" "uncommitted state"
  assert_eq "$(remote_head a)" "$(head_of a)" HEAD
  [ -n "$(stashed_sha)" ] || fail "stash sha not printed: $ERR"
  [ -z "$(keeps)" ] || fail "stash left: $(keeps)"
}
t_keep_overlap() {
  make_repo a; echo local >"$WS/a/README"; remote_commit a README remote
  STUB_CLAUDE_MODE=resolve run_reposync --dirty=keep; assert_rc 1
  local sha; sha=$(stashed_sha)
  assert_eq "a${TAB}main${TAB}merged${TAB}ok (local changes merged with conflicts; originals kept in $sha)" "$(row a)" row
  assert_contains "$OUT" "WARN a: leftover reposync stash $sha"
  keeps | grep -q "^$sha On main: reposync-keep " || fail "stash entry: $(keeps)"
  grep -qx local "$WS/a/README" || fail "README lost local: $(cat "$WS/a/README")"
  grep -qx remote "$WS/a/README" || fail "README lost remote: $(cat "$WS/a/README")"
  assert_eq "" "$(git -C "$WS/a" ls-files -u)" unmerged
  assert_eq "" "$(git -C "$WS/a" diff --cached)" staged
}
t_keep_untracked_collision() {
  make_repo a; echo mine >"$WS/a/n"; remote_commit a n theirs
  local p; p=$(head_of a)
  run_reposync --dirty=keep; assert_rc 1
  case $(result) in failed:would-overwrite-ignored*) ;; *) fail "result: $(result)";; esac
  assert_eq mine "$(cat "$WS/a/n")" "local n"
  assert_eq "$p" "$(head_of a)" HEAD
  [ -z "$(keeps)" ] || fail "stash left: $(keeps)"
}
t_keep_user_stash_clean_repo() {
  make_repo a; echo wip >"$WS/a/README"; git -C "$WS/a" stash -q; remote_commit a r x
  local before; before=$(git -C "$WS/a" stash list)
  run_reposync --dirty=keep; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged${TAB}ok" "$(row a)" row
  assert_eq "$before" "$(git -C "$WS/a" stash list)" "stash list"
}
t_keep_claude_drops_stash() {
  make_repo a; echo local >"$WS/a/README"; remote_commit a README remote
  STUB_CLAUDE_MODE=drop-stash run_reposync --dirty=keep; assert_rc 1
  local sha; sha=$(stashed_sha)
  [ -n "$sha" ] || fail "stash sha not printed: $ERR"
  assert_eq "failed:keep-restore (changes in $sha)" "$(result)" result
  assert_eq "" "$(git -C "$WS/a" ls-files -u)" unmerged
  git -C "$WS/a" stash show -p "$sha" | grep -qx '+local' || fail "user edit not in $sha"
}
t_keep_push_fail_restores() {
  make_repo a; local_commit a f x; echo dirty >>"$WS/a/README"; echo u >"$WS/a/u.txt"
  exit1_hook "$REMOTES/a.git/hooks/pre-receive"
  local before; before=$(wt)
  run_reposync --dirty=keep; assert_rc 1
  case $(result) in failed:push*) ;; *) fail "result: $(result)";; esac
  assert_eq "$before" "$(wt)" "uncommitted state"
  [ -z "$(keeps)" ] || fail "stash left: $(keeps)"
}
t_dry_run_dirty_modes() {
  make_repo a; remote_commit a r x; echo mod >>"$WS/a/README"; echo u >"$WS/a/u.txt"
  local m before
  snap7() {
    (cd "$WS/a" && git rev-parse HEAD && git status --porcelain && git diff && git diff --cached \
      && git stash list --format=%H && git for-each-ref refs/heads && cat .git/config)
  }
  for m in commit keep; do
    before=$(snap7)
    run_reposync --dry-run --dirty=$m; assert_rc 0
    assert_eq "$before" "$(snap7)" "$m: repo state"
    assert_eq dirty "$(row a | cut -f5)" "$m: state column"
  done
  [ -s "$STUB_CLAUDE_LOG" ] && fail "claude called in dry-run"
  true
}
t_keep_sigterm_during_merge_conflict() {
  make_conflict a; echo dirty >>"$WS/a/other.txt"; echo u >"$WS/a/u.txt"
  local p before i=0; p=$(head_of a); before=$(wt)
  REPOSYNC_CLAUDE_TIMEOUT=600 STUB_CLAUDE_MODE=sleep STUB_MARKER=$T/m start_reposync_bg --dirty=keep
  while [ ! -e "$T/m" ]; do
    [ "$i" -ge 100 ] && { kill -KILL "$BGPID"; fail "stub never started"; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$BGPID"
  wait_bg 15; assert_rc 143
  assert_eq failed:interrupted "$(result)" result
  assert_eq "$p" "$(head_of a)" HEAD
  git -C "$WS/a" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "MERGE_HEAD left"
  assert_eq "$before" "$(wt)" "uncommitted state"
  [ -z "$(keeps)" ] || fail "stash left: $(keeps)"
  kill -0 "$(cat "$T/stub.pid")" 2>/dev/null && fail "stub still alive"
  true
}
t_keep_sigterm_during_stash_conflict() {
  # a signal during the §8.2 claude call: no second apply, conflicts unstaged, stash kept and named in the row.
  make_repo a; echo local >"$WS/a/README"; remote_commit a README remote
  local i=0 sha
  REPOSYNC_CLAUDE_TIMEOUT=600 STUB_CLAUDE_MODE=sleep STUB_MARKER=$T/m start_reposync_bg --dirty=keep
  while [ ! -e "$T/m" ]; do
    [ "$i" -ge 100 ] && { kill -KILL "$BGPID"; fail "stub never started"; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$BGPID"
  wait_bg 15; assert_rc 143
  sha=$(stashed_sha)
  assert_eq "failed:interrupted (changes in $sha)" "$(result)" result
  assert_eq "$(remote_head a)" "$(head_of a)" HEAD
  assert_eq "" "$(git -C "$WS/a" ls-files -u)" unmerged
  keeps | grep -q "^$sha " || fail "stash entry gone: $(keeps)"
  git -C "$WS/a" stash show -p "$sha" | grep -qx '+local' || fail "user edit not in $sha"
}
t_commit_sigterm_during_message() {
  # §7.6 step 0 from a signal: index put back from SAVED_TREE, worktree untouched, no commit.
  make_repo a; echo s >"$WS/a/s.txt"; git -C "$WS/a" add s.txt; echo u >>"$WS/a/README"; echo n >"$WS/a/new.txt"
  local p before i=0; p=$(head_of a); before=$(wt)
  STUB_MSG_MODE=sleep STUB_MARKER=$T/m start_reposync_bg --dirty=commit
  while [ ! -e "$T/m" ]; do
    [ "$i" -ge 100 ] && { kill -KILL "$BGPID"; fail "stub never started"; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$BGPID"
  wait_bg 15; assert_rc 143
  assert_eq "a${TAB}main${TAB}none${TAB}failed:interrupted" "$(row a)" row
  assert_eq "$p" "$(head_of a)" HEAD
  assert_eq "$before" "$(wt)" "uncommitted state"
  kill -0 "$(cat "$T/stub.pid")" 2>/dev/null && fail "stub still alive"
  true
}
