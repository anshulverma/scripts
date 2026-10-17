#!/usr/bin/env bash
t_help()        { run_reposync --help; assert_rc 0; assert_contains "$OUT" "--dirty=skip|commit|keep"; assert_contains "$OUT" "Exit codes"; }
t_bad_flag()    { run_reposync --bogus; assert_rc 2; assert_contains "$ERR" "usage"; }
t_bad_dirty()   { run_reposync --dirty=maybe; assert_rc 2; }
t_missing_arg() { bin_reposync --workspace; assert_rc 2; assert_contains "$ERR" "usage"; }
t_missing_ws()  { bin_reposync --workspace "$T/nope"; assert_rc 2; }
t_ws_from_env() { mkdir -p "$T/w2"; WORKSPACE_DIR=$T/w2 bin_reposync; assert_rc 0; }
t_ws_from_constants() { mkdir -p "$HOME/.config/dotsync2" "$T/w3"; echo "export WORKSPACE_DIR=\"\${WORKSPACE_DIR:-$T/w3}\"" > "$HOME/.config/dotsync2/constants.env"; bin_reposync; assert_rc 0; }
t_lock_held()   { sleep 30 & p=$!; mkdir -p "$HOME/.local/state/reposync/lock"; echo $p > "$HOME/.local/state/reposync/lock/pid"; make_repo a; local_commit a f x; h=$(git -C "$WS/a" rev-parse HEAD); r=$(remote_head a); run_reposync; assert_rc 3; assert_contains "$ERR" "another run (pid $p)"; assert_eq "" "$OUT" "no rows"; assert_eq "$h" "$(git -C "$WS/a" rev-parse HEAD)" "head"; assert_eq "$r" "$(remote_head a)" "nothing pushed"; [ -f "$HOME/.local/state/reposync/lock/pid" ] || fail "lock removed"; kill $p; }
t_lock_no_pid() { mkdir -p "$HOME/.local/state/reposync/lock"; run_reposync; assert_rc 3; }
t_lock_stale()  { mkdir -p "$HOME/.local/state/reposync/lock"; sh -c "exit 0" & dead=$!; wait $dead; echo $dead > "$HOME/.local/state/reposync/lock/pid"; run_reposync; assert_rc 0; [ ! -d "$HOME/.local/state/reposync/lock" ] || fail "lock not released"; }
t_empty_ws()    { run_reposync; assert_rc 0; assert_eq "" "$OUT" "no rows"; }
