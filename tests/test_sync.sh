#!/usr/bin/env bash
TAB=$(printf '\t')
# hook FILE BODY: write an executable sh hook.
hook() { printf '#!/bin/sh\n%s\n' "$2" >"$1" && chmod +x "$1"; }
head_of() { git -C "$WS/$1" rev-parse HEAD; }
# gone_setup: branch feat pushed without -u, fetched, then deleted on the remote.
gone_setup() {
  make_repo a; git -C "$WS/a" checkout -qb feat; local_commit a f x
  git -C "$WS/a" push -q origin HEAD:refs/heads/feat 2>/dev/null; git -C "$WS/a" fetch -q origin
  git -C "$WS/a" rev-parse -q --verify refs/remotes/origin/feat >/dev/null || fail "setup: no origin/feat"
  git --git-dir="$REMOTES/a.git" branch -q -D feat
}
# guard_check EXPECTED_CONTENT: row failed:would-overwrite-ignored, secret file untouched, HEAD unchanged.
guard_check() {
  local file=$1 want=$2 pre=$3
  run_reposync; assert_rc 1
  case $(row a) in "a${TAB}main${TAB}none${TAB}failed:would-overwrite-ignored"*) ;; *) fail "row: $(row a)";; esac
  assert_eq "$want" "$(cat "$WS/a/$file")" "ignored file content"
  assert_eq "$pre" "$(head_of a)" HEAD
}

t_ahead_push() {
  make_repo a; local_commit a f x; run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}pushed${TAB}ok" "$(row a)" row
  assert_eq "$(head_of a)" "$(remote_head a)" remote
}
t_behind_ff() {
  make_repo a; remote_commit a f y; run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged${TAB}ok" "$(row a)" row
  assert_eq "$(remote_head a)" "$(head_of a)" HEAD
  case $ERR in *"Everything up-to-date"*|*"To file://"*) fail "pushed: $ERR";; esac
}
t_diverged_merge() {
  make_repo a; local_commit a f x; remote_commit a g y
  local pre rpre; pre=$(head_of a); rpre=$(remote_head a)
  run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}merged+pushed${TAB}ok" "$(row a)" row
  assert_eq "$pre $rpre" "$(git -C "$WS/a" rev-parse HEAD^1 HEAD^2 | tr '\n' ' ' | sed 's/ $//')" parents
  assert_eq "$(head_of a)" "$(remote_head a)" remote
}
t_no_upstream() {
  make_repo a; git -C "$WS/a" checkout -qb feat; local_commit a f x
  run_reposync; assert_rc 0
  assert_eq "a${TAB}feat${TAB}set-upstream+pushed${TAB}ok" "$(row a)" row
  assert_eq refs/heads/feat "$(git -C "$WS/a" config branch.feat.merge)" merge-config
  assert_eq "$(head_of a)" "$(remote_head a feat)" remote
}
t_slash_branch() {
  make_repo a feature/x; local_commit a f x; run_reposync; assert_rc 0
  assert_eq "a${TAB}feature/x${TAB}pushed${TAB}ok" "$(row a)" row
  assert_eq "$(head_of a)" "$(remote_head a feature/x)" remote
}
t_upstream_gone() {
  gone_setup
  run_reposync; assert_eq "a${TAB}feat${TAB}none${TAB}skipped:upstream-gone" "$(row a)" "run 1"
  assert_eq refs/heads/feat "$(git -C "$WS/a" config branch.feat.merge)" merge-config
  run_reposync; assert_eq "a${TAB}feat${TAB}none${TAB}skipped:upstream-gone" "$(row a)" "run 2"
  git --git-dir="$REMOTES/a.git" rev-parse -q --verify refs/heads/feat >/dev/null && fail "feat recreated"
  true
}
t_upstream_gone_after_dryrun() {
  gone_setup; git config --global fetch.prune true
  run_reposync --dry-run
  git -C "$WS/a" config --get branch.feat.merge >/dev/null && fail "dry-run wrote config"
  run_reposync; assert_eq "a${TAB}feat${TAB}none${TAB}skipped:upstream-gone" "$(row a)" "real run"
  git --git-dir="$REMOTES/a.git" rev-parse -q --verify refs/heads/feat >/dev/null && fail "feat recreated"
  true
}
t_ignored_guard_exact() {
  make_repo a; echo secret.env >>"$WS/a/.git/info/exclude"; echo mine >"$WS/a/secret.env"
  remote_commit a secret.env theirs
  guard_check secret.env mine "$(head_of a)"
}
t_ignored_guard_rename() {
  make_repo a; remote_commit a tmpl.env tmpl; git -C "$WS/a" pull -q --ff-only 2>/dev/null
  echo secret.env >>"$WS/a/.git/info/exclude"; echo mine >"$WS/a/secret.env"
  (cd "$T/scratch/a" && git mv tmpl.env secret.env && git commit -qm mv && git push -q origin HEAD:refs/heads/main 2>/dev/null) \
    || fail "setup: rename"
  guard_check secret.env mine "$(head_of a)"
}
t_ignored_guard_dirfile() {
  make_repo a; echo out/ >>"$WS/a/.git/info/exclude"; mkdir "$WS/a/out"; echo mine >"$WS/a/out/data"
  remote_commit a out theirs
  guard_check out/data mine "$(head_of a)"
}
t_ignored_guard_ahead_ok() {
  make_repo a; remote_commit a cfg.local v1; git -C "$WS/a" pull -q --ff-only 2>/dev/null
  (cd "$WS/a" && git rm -q --cached cfg.local && echo cfg.local >.gitignore && git add .gitignore \
    && git commit -qm untrack) || fail "setup: untrack"
  run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}pushed${TAB}ok" "$(row a)" row
  assert_eq v1 "$(cat "$WS/a/cfg.local")" cfg.local
}
t_merge_hook_fails() {
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$WS/a/.git/hooks/pre-merge-commit" 'echo hookfail >&2; exit 1'
  local pre rpre; pre=$(head_of a); rpre=$(remote_head a)
  run_reposync; assert_rc 1
  case $(row a) in "a${TAB}main${TAB}none${TAB}failed:merge"*hookfail*) ;; *) fail "row: $(row a)";; esac
  assert_eq "$pre" "$(head_of a)" HEAD
  [ -f "$WS/a/.git/MERGE_HEAD" ] && fail "MERGE_HEAD left"
  assert_eq "" "$(git -C "$WS/a" status --porcelain)" status
  assert_eq "$rpre" "$(remote_head a)" remote
  [ -s "$STUB_CLAUDE_LOG" ] && fail "claude called"
  true
}
t_push_hook_reject() {
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$REMOTES/a.git/hooks/pre-receive" "echo x >> '$T/hook.log'; exit 1"
  run_reposync; assert_rc 1
  assert_eq "a${TAB}main${TAB}merged${TAB}failed:push" "$(row a)" row
  assert_eq 3 "$(git -C "$WS/a" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "merge kept (sha + 2 parents)"
  assert_eq 1 "$(wc -l <"$T/hook.log" | tr -d ' ')" "push attempts"
}
t_push_race_retry() {
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$WS/a/.git/hooks/post-merge" "[ -e '$T/raced' ] && exit 0
touch '$T/raced'
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cd '$T/scratch/a' && echo race >race.txt && git add race.txt && git commit -qm race && git push -q origin HEAD:refs/heads/main"
  run_reposync; assert_rc 0
  [ -e "$T/raced" ] || fail "race hook did not run"
  assert_contains "$ERR" "(fetch first)"
  assert_eq "a${TAB}main${TAB}merged+pushed${TAB}ok" "$(row a)" row
  local raced; raced=$(git -C "$T/scratch/a" rev-parse HEAD)
  git --git-dir="$REMOTES/a.git" merge-base --is-ancestor "$raced" refs/heads/main || fail "raced commit lost"
  assert_eq "$(remote_head a)" "$(head_of a)" "local == remote"
}
t_ancestry_guard() {
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$WS/a/.git/hooks/post-merge" 'git reset -q --hard HEAD~1'
  local pre rpre; pre=$(head_of a); rpre=$(remote_head a)
  run_reposync; assert_rc 1
  case $(row a) in *"${TAB}failed:ancestry") ;; *) fail "row: $(row a)";; esac
  assert_eq "$pre" "$(head_of a)" HEAD
  assert_eq "$rpre" "$(remote_head a)" remote
}
t_merge_rescues_untracked() {
  # restore step 1: a file created by the merge (hook) after SNAP is moved to rescue, never deleted.
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$WS/a/.git/hooks/pre-merge-commit" 'mkdir -p "sub dir"; echo keep >"sub dir/new file"; exit 1'
  local pre; pre=$(head_of a)
  run_reposync; assert_rc 1
  case $(row a) in *"failed:merge"*"untracked files moved to $HOME/.local/state/reposync/rescue/a/"*) ;; *) fail "row: $(row a)";; esac
  local f; f=$(find "$HOME/.local/state/reposync/rescue/a" -type f -name 'new file')
  assert_eq keep "$(cat "$f")" rescued
  case $f in *"/sub dir/new file") ;; *) fail "rel path: $f";; esac
  assert_eq "$pre" "$(head_of a)" HEAD
  assert_eq "" "$(git -C "$WS/a" status --porcelain)" status
}
t_ignored_guard_quoted_dirfile() {
  # names git C-quotes (core.quotePath) must still collide: compare raw (NUL-delimited) names.
  make_repo a; printf 'q"d/\n' >>"$WS/a/.git/info/exclude"; mkdir "$WS/a/q\"d"; echo mine >"$WS/a/q\"d/data"
  remote_commit a 'q"d' theirs
  guard_check 'q"d/data' mine "$(head_of a)"
}
# iso_at EPOCH: ISO UTC timestamp (GNU or BSD date).
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
t_rescue_odd_names() {
  make_repo a; local_commit a f x; remote_commit a g y
  local nl s now rd r dir
  nl=$(printf 'n\nl.'); nl=${nl%.}
  hook "$WS/a/.git/hooks/post-merge" "printf x >'a\"b'
printf y >'$nl'
printf z >'b\\s'
git reset -q --hard HEAD~1"
  # pre-existing rescued files for the next seconds: a later move must never overwrite them.
  rd=$HOME/.local/state/reposync/rescue/a; now=$(date +%s)
  for s in 0 1 2 3 4 5 6 7 8 9 10 11; do mkdir -p "$rd/$(iso_at $((now + s)))"; echo old >"$rd/$(iso_at $((now + s)))/a\"b"; done
  run_reposync; assert_rc 1
  r=$(row a)
  case $r in *"failed:ancestry (untracked files moved to $rd/"*")") ;; *) fail "row: $r";; esac
  dir=${r#*untracked files moved to }; dir=${dir%)}
  assert_eq x "$(cat "$dir/a\"b.1")" 'a"b moved to a"b.1'
  assert_eq y "$(cat "$dir/$nl")" "newline name moved"
  assert_eq z "$(cat "$dir/b\\s")" "backslash name moved"
  for s in "$rd"/*/a\"b; do assert_eq old "$(cat "$s")" "seed $s overwritten"; done
  assert_eq "" "$(git -C "$WS/a" status --porcelain)" status
}
t_rescue_note_only_when_moved() {
  make_repo a; local_commit a f x; remote_commit a g y
  hook "$WS/a/.git/hooks/post-merge" 'git reset -q --hard HEAD~1'
  run_reposync; assert_rc 1
  assert_eq "a${TAB}main${TAB}merged${TAB}failed:ancestry" "$(row a)" row
  [ -e "$HOME/.local/state/reposync/rescue" ] && fail "rescue dir created with nothing to move"
  true
}
t_tag_named_like_branch() {
  # B must be the branch name even when a tag shares it (symbolic-ref --short would print heads/main).
  make_repo a; git -C "$WS/a" tag main
  run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}none${TAB}ok" "$(row a)" "up-to-date row"
  assert_eq refs/heads/main "$(git -C "$WS/a" symbolic-ref HEAD)" "up-to-date branch"
  local_commit a f x
  run_reposync; assert_rc 0
  assert_eq "a${TAB}main${TAB}pushed${TAB}ok" "$(row a)" "ahead row"
  assert_eq refs/heads/main "$(git -C "$WS/a" symbolic-ref HEAD)" "ahead branch"
  assert_eq "$(git -C "$WS/a" rev-parse refs/heads/main)" "$(remote_head a)" "remote refs/heads/main"
  git -C "$WS/a" rev-parse -q --verify refs/heads/heads/main >/dev/null && fail "refs/heads/heads/main created"
  git --git-dir="$REMOTES/a.git" rev-parse -q --verify refs/heads/heads/main >/dev/null && fail "remote heads/main created"
  true
}
