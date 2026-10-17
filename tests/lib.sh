#!/usr/bin/env bash
# Test helpers. Sourced by tests/run.sh; each t_* case runs in a subshell after setup_env.
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPOSYNC=$(cd "$TESTS/.." && pwd -P)/bin/reposync

fail() { echo "$1" >&2; exit 1; }

setup_env() {
  T=$(mktemp -d); export T
  export HOME=$T/home WS=$T/ws REMOTES=$T/remotes
  mkdir -p "$HOME" "$WS" "$REMOTES"
  unset XDG_STATE_HOME WORKSPACE_DIR
  cat >"$HOME/.gitconfig" <<GC
[user]
	name = Test
	email = t@example.com
[init]
	defaultBranch = main
[merge]
	conflictStyle = zdiff3
GC
  export PATH=$TESTS/stubs:$PATH
  export STUB_CLAUDE_LOG=$T/claude.stdin
  # shellcheck disable=SC2064
  trap "rm -rf '$T'" EXIT
}

# make_repo NAME [BRANCH]: bare remote with one commit, cloned into $WS/NAME with upstream set.
make_repo() {
  local n=$1 b=${2:-main}
  git init -q --bare -b "$b" "$REMOTES/$n.git" || fail "make_repo: init bare"
  git clone -q "file://$REMOTES/$n.git" "$T/seed-$n" 2>/dev/null || fail "make_repo: seed clone"
  (cd "$T/seed-$n" && git checkout -q -B "$b" && echo hello >README && git add README \
    && git commit -q -m init && git push -q -u origin "$b" 2>/dev/null) || fail "make_repo: seed push"
  rm -rf "$T/seed-$n"
  git clone -q "file://$REMOTES/$n.git" "$WS/$n" 2>/dev/null || fail "make_repo: clone"
}

# remote_commit NAME PATH CONTENT [BRANCH]: commit via a scratch clone and push to the remote.
remote_commit() {
  local n=$1 p=$2 c=$3 b=${4:-main}
  if [ ! -d "$T/scratch/$n" ]; then
    mkdir -p "$T/scratch"
    git clone -q "file://$REMOTES/$n.git" "$T/scratch/$n" 2>/dev/null || fail "remote_commit: clone"
  fi
  (cd "$T/scratch/$n" && git fetch -q origin \
    && { git checkout -q "$b" 2>/dev/null || git checkout -q -b "$b" "origin/$b" 2>/dev/null || git checkout -q -b "$b"; } \
    && { git merge -q --ff-only "origin/$b" 2>/dev/null || true; } \
    && mkdir -p "$(dirname "$p")" && printf '%s\n' "$c" >"$p" && git add -A \
    && git commit -q -m "remote $p" && git push -q origin "HEAD:refs/heads/$b" 2>/dev/null) \
    || fail "remote_commit: $n $p"
}

# local_commit NAME PATH CONTENT: commit in $WS/NAME on its current branch.
local_commit() {
  (cd "$WS/$1" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" >"$2" && git add -A \
    && git commit -q -m "local $2") || fail "local_commit: $1 $2"
}

remote_head() { git --git-dir="$REMOTES/$1.git" rev-parse "refs/heads/${2:-main}"; }

# _run CMD...: run from $T (never the scripts repo), set OUT ERR RC.
_run() {
  (cd "$T" && "$@") >"$T/run.out" 2>"$T/run.err"
  RC=$?
  OUT=$(cat "$T/run.out"); ERR=$(cat "$T/run.err")
}
run_reposync() { _run "$REPOSYNC" --workspace "$WS" "$@"; }
bin_reposync() { _run "$REPOSYNC" "$@"; }

# start_reposync_bg ARGS...: the script itself runs in the background so BGPID is reposync's pid.
start_reposync_bg() {
  "$REPOSYNC" --workspace "$WS" "$@" >"$T/bg.out" 2>"$T/bg.err" </dev/null &
  BGPID=$!
}

# wait_bg SECS: fail if still alive after SECS, else collect RC OUT ERR.
wait_bg() {
  local i=0 max=$(( $1 * 10 ))
  while kill -0 "$BGPID" 2>/dev/null; do
    [ "$i" -ge "$max" ] && fail "wait_bg: pid $BGPID still running after $1s"
    sleep 0.1; i=$((i + 1))
  done
  wait "$BGPID"; RC=$?
  OUT=$(cat "$T/bg.out"); ERR=$(cat "$T/bg.err")
}

row() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$1 == n'; }

assert_eq()       { [ "$1" = "$2" ] || fail "$3: expected [$1] got [$2]"; }
assert_contains() { case $1 in *"$2"*) ;; *) fail "expected [$1] to contain [$2]";; esac; }
assert_rc()       { [ "$RC" = "$1" ] || fail "rc: expected $1 got $RC (out=[$OUT] err=[$ERR])"; }
