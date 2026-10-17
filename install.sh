#!/usr/bin/env bash
# Symlink bin/* into ~/.local/bin and install one daily cron line tagged "# reposync:managed".
set -u
REPO=$(cd -P "$(dirname "$0")" && pwd) || exit 1
BINDIR=$HOME/.local/bin
mkdir -p "$BINDIR" || exit 1

for src in "$REPO"/bin/*; do
  [ -f "$src" ] || continue
  f=$(basename "$src"); dst=$BINDIR/$f
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    echo "ok $dst"
  elif [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "skip $dst: exists and is not ours"
  else
    ln -s "$src" "$dst" || exit 1
    echo "linked $dst -> $src"
  fi
done

TARGET=$BINDIR/reposync
if [ ! -L "$TARGET" ] || [ "$(readlink "$TARGET")" != "$REPO/bin/reposync" ]; then
  echo "skip cron: $TARGET is not ours"
  exit 0
fi
command -v claude >/dev/null 2>&1 || echo "warning: claude not found; conflict resolution will be unavailable" >&2
if ! command -v crontab >/dev/null 2>&1; then
  echo "warning: crontab not found; skipping cron" >&2
  exit 0
fi

STATE_BASE=${XDG_STATE_HOME:-$HOME/.local/state}
STATE_DIR=$STATE_BASE/reposync
P=
for c in git claude node; do
  p=$(command -v "$c") || continue
  case $p in /*) ;; *) continue;; esac
  d=$(dirname "$p")
  case ":$P:" in *":$d:"*) ;; *) P=${P:+$P:}$d;; esac
done
P=${P:+$P:}$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
LINE="17 9 * * * mkdir -p $STATE_DIR && XDG_STATE_HOME=$STATE_BASE PATH=$P $TARGET > $STATE_DIR/cron.log 2>&1 # reposync:managed"
case $LINE in *%*) echo "warning: '%' in cron line (paths); skipping cron" >&2; exit 0;; esac

ERRF=$(mktemp) || exit 1
trap 'rm -f "$ERRF"' EXIT
if CUR=$(crontab -l 2>"$ERRF"); then :
elif grep -qi 'no crontab' "$ERRF"; then CUR=
else
  echo "crontab -l failed: $(cat "$ERRF")" >&2
  exit 1
fi
NEW=$(printf '%s\n' "$CUR" | grep -vF '# reposync:managed' || true)
{ [ -n "$NEW" ] && printf '%s\n' "$NEW"; printf '%s\n' "$LINE"; } | crontab - || { echo "crontab write failed" >&2; exit 1; }
echo "cron installed: $LINE"
