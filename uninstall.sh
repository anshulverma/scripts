#!/usr/bin/env bash
# Remove our ~/.local/bin symlinks and the "# reposync:managed" cron line. Keeps state dir and repo.
set -u
REPO=$(cd -P "$(dirname "$0")" && pwd) || exit 1
BINDIR=$HOME/.local/bin

for src in "$REPO"/bin/*; do
  [ -f "$src" ] || continue
  dst=$BINDIR/$(basename "$src")
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    rm -f "$dst" && echo "removed $dst"
  fi
done

if ! command -v crontab >/dev/null 2>&1; then
  echo "warning: crontab not found; skipping cron" >&2
  exit 0
fi
ERRF=$(mktemp) || exit 1
trap 'rm -f "$ERRF"' EXIT
if CUR=$(crontab -l 2>"$ERRF"); then :
elif grep -qi 'no crontab' "$ERRF"; then
  echo "no crontab; nothing to remove"
  exit 0
else
  echo "crontab -l failed: $(cat "$ERRF")" >&2
  exit 1
fi
if ! printf '%s\n' "$CUR" | grep -qF '# reposync:managed'; then
  echo "no managed cron line; nothing to remove"
  exit 0
fi
NEW=$(printf '%s\n' "$CUR" | grep -vF '# reposync:managed' || true)
if [ -z "$NEW" ]; then
  crontab -r || { echo "crontab -r failed" >&2; exit 1; }
else
  printf '%s\n' "$NEW" | crontab - || { echo "crontab write failed" >&2; exit 1; }
fi
echo "cron line removed"
