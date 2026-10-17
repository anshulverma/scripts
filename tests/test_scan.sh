#!/usr/bin/env bash
TAB=$(printf '\t')
# snap_repos NAME...: HEAD + index + porcelain status for each repo (fetch may move remote refs, never these).
snap_repos() { local n; for n in "$@"; do echo "== $n"; git -C "$WS/$n" rev-parse HEAD; git -C "$WS/$n" ls-files -s; git -C "$WS/$n" status --porcelain; done; }

t_not_git() { mkdir "$WS/plain"; run_reposync; assert_eq "plain${TAB}-${TAB}none${TAB}skipped:not-git" "$(row plain)" row; }
t_no_origin() { git init -q "$WS/x"; (cd "$WS/x" && echo a >f && git add f && git commit -q -m c); run_reposync; assert_eq "x${TAB}main${TAB}none${TAB}skipped:no-origin" "$(row x)" row; }
t_detached() { make_repo a; git -C "$WS/a" checkout -q --detach; run_reposync; assert_eq "a${TAB}-${TAB}none${TAB}skipped:detached-head" "$(row a)" row; }
t_no_commits() {
  git init -q "$WS/n"; git -C "$WS/n" remote add origin "file://$REMOTES/n.git"; echo hi >"$WS/n/u"
  run_reposync; assert_eq "n${TAB}main${TAB}none${TAB}skipped:no-commits" "$(row n)" row
  assert_eq hi "$(cat "$WS/n/u")" untracked
}
t_in_progress() {
  make_repo a; local_commit a f x; remote_commit a f y; git -C "$WS/a" fetch -q origin
  git -C "$WS/a" merge origin/main >/dev/null 2>&1
  [ -f "$WS/a/.git/MERGE_HEAD" ] || fail "setup: no MERGE_HEAD"
  run_reposync; assert_eq "a${TAB}main${TAB}none${TAB}skipped:in-progress-op" "$(row a)" row
}
t_unmerged_no_merge_head() {
  make_repo a; local m
  (cd "$WS/a" && echo base >f && git add f && git commit -q -m base && echo e1 >f && git stash -q \
    && echo e2 >f && git commit -q -am e2 && git stash pop -q) >/dev/null 2>&1
  [ -n "$(git -C "$WS/a" ls-files -u)" ] || fail "setup: no unmerged entries"
  [ ! -f "$WS/a/.git/MERGE_HEAD" ] || fail "setup: MERGE_HEAD exists"
  local before; before=$({ snap_repos a; git -C "$WS/a" stash list --format=%H; git -C "$WS/a" ls-files -u; })
  for m in "" --dirty=commit --dirty=keep; do
    run_reposync $m; assert_eq "a${TAB}main${TAB}none${TAB}skipped:in-progress-op" "$(row a)" "row [$m]"
    assert_eq "$before" "$({ snap_repos a; git -C "$WS/a" stash list --format=%H; git -C "$WS/a" ls-files -u; })" "unchanged [$m]"
  done
}
t_upstream_mismatch() { make_repo a; git -C "$WS/a" config branch.main.merge refs/heads/other; run_reposync; assert_eq "a${TAB}main${TAB}none${TAB}skipped:upstream-mismatch" "$(row a)" row; }
t_dirty_skip() { make_repo a; echo u >"$WS/a/u"; run_reposync; assert_eq "a${TAB}main${TAB}none${TAB}skipped:dirty" "$(row a)" row; assert_rc 0; }
t_fetch_fail() {
  make_repo a; make_repo b; git -C "$WS/a" remote set-url origin file:///nonexistent.git
  run_reposync; assert_rc 1
  assert_eq "a${TAB}main${TAB}none${TAB}failed:fetch" "$(row a)" "row a"
  assert_eq "b${TAB}main${TAB}none${TAB}ok" "$(row b)" "row b"
  assert_contains "$ERR" nonexistent
}
t_up_to_date() {
  make_repo a; run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}none${TAB}ok" "$(row a)" row
  case $ERR in *"Everything up-to-date"*|*"To file://"*) fail "pushed: $ERR";; esac
}
t_dry_run_states() {
  local n before
  for n in ahead behind diverged uptodate noup dirty pr; do make_repo $n; done
  local_commit ahead f x; remote_commit behind f y; local_commit diverged f x; remote_commit diverged g y
  git -C "$WS/noup" checkout -q -b feat; echo u >"$WS/dirty/u"
  git -C "$WS/pr" push -q origin HEAD:refs/heads/feat 2>/dev/null
  git --git-dir="$REMOTES/pr.git" branch -q -D feat; git -C "$WS/pr" config fetch.prune true
  before=$(snap_repos ahead behind diverged uptodate noup dirty pr)
  run_reposync --dry-run; assert_rc 0
  assert_eq "ahead${TAB}main${TAB}would-pushed${TAB}ok${TAB}ahead" "$(row ahead)" ahead
  assert_eq "behind${TAB}main${TAB}would-merged${TAB}ok${TAB}behind" "$(row behind)" behind
  assert_eq "diverged${TAB}main${TAB}would-merged+pushed${TAB}ok${TAB}diverged" "$(row diverged)" diverged
  assert_eq "uptodate${TAB}main${TAB}none${TAB}ok${TAB}up-to-date" "$(row uptodate)" uptodate
  assert_eq "noup${TAB}feat${TAB}would-set-upstream+pushed${TAB}ok${TAB}no-upstream" "$(row noup)" noup
  assert_eq "dirty${TAB}main${TAB}none${TAB}skipped:dirty${TAB}dirty" "$(row dirty)" dirty
  assert_eq "$before" "$(snap_repos ahead behind diverged uptodate noup dirty pr)" "repos unchanged"
  git -C "$WS/pr" rev-parse -q --verify refs/remotes/origin/feat >/dev/null || fail "dry-run pruned origin/feat"
}
t_dry_run_skip_state() { mkdir "$WS/plain"; run_reposync --dry-run; assert_eq "plain${TAB}-${TAB}none${TAB}skipped:not-git${TAB}skipped:not-git" "$(row plain)" row; }
t_space_in_name() { make_repo "my repo"; run_reposync; assert_contains "$OUT" "my repo${TAB}main${TAB}"; assert_eq "my repo${TAB}main${TAB}none${TAB}ok" "$(row "my repo")" row; }
t_symlinked_ws() {
  make_repo a; ln -s "$WS" "$T/wslink"; bin_reposync --workspace "$T/wslink"
  assert_eq "a${TAB}main${TAB}none${TAB}ok" "$(row a)" row
}
t_leftover_warn() {
  make_repo a; echo u >"$WS/a/u"
  git -C "$WS/a" stash push -q -u -m "reposync-keep 2026-01-01T00:00:00Z"
  local sha; sha=$(git -C "$WS/a" stash list --format=%H)
  run_reposync; assert_rc 1; assert_contains "$OUT" "WARN a: leftover reposync stash $sha"
  run_reposync --dry-run; assert_rc 1; assert_contains "$OUT" "WARN a: leftover reposync stash $sha"
}
t_three_repos_sorted() { make_repo c; make_repo a; make_repo b; run_reposync; assert_eq "a b c" "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" order; }
