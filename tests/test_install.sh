#!/usr/bin/env bash
# install.sh / uninstall.sh against a stub crontab and a temp HOME.
INSTALL=$(cd "$TESTS/.." && pwd -P)/install.sh
UNINSTALL=$(cd "$TESTS/.." && pwd -P)/uninstall.sh
REPO_ABS=$(cd "$TESTS/.." && pwd -P)

need_stub() { [ "$(command -v crontab)" = "$TESTS/stubs/crontab" ] || fail "crontab resolves to $(command -v crontab), not the stub"; }
managed_count() { grep -c '# reposync:managed' "$HOME/crontab.txt"; }
wrote() { grep -qx -e '-' -e '-r' "$HOME/crontab.calls" 2>/dev/null; }  # any write call recorded

t_install_twice() {
  need_stub
  echo '5 5 * * * echo hi' >"$HOME/crontab.txt"
  _run "$INSTALL"; assert_rc 0
  _run "$INSTALL"; assert_rc 0
  assert_eq 1 "$(managed_count)" "managed lines"
  grep -qxF '5 5 * * * echo hi' "$HOME/crontab.txt" || fail "foreign line lost"
  line=$(grep '# reposync:managed' "$HOME/crontab.txt")
  printf '%s\n' "$line" | grep -Eq '^17 9 \* \* \* mkdir -p .*XDG_STATE_HOME=.* PATH=.* .*/\.local/bin/reposync > .*/cron\.log 2>&1 # reposync:managed$' \
    || fail "bad cron line: $line"
  case $line in *%*) fail "percent in cron line";; esac
  assert_contains "$line" "mkdir -p $HOME/.local/state/reposync && XDG_STATE_HOME=$HOME/.local/state PATH="
  assert_contains "$line" "$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin $HOME/.local/bin/reposync > $HOME/.local/state/reposync/cron.log"
  assert_eq "$REPO_ABS/bin/reposync" "$(readlink "$HOME/.local/bin/reposync")" "symlink target"
}

t_install_xdg_state() {
  need_stub
  XDG_STATE_HOME=$T/xs _run "$INSTALL"; assert_rc 0
  assert_contains "$(cat "$HOME/crontab.txt")" "mkdir -p $T/xs/reposync && XDG_STATE_HOME=$T/xs PATH="
  assert_contains "$(cat "$HOME/crontab.txt")" "> $T/xs/reposync/cron.log 2>&1 # reposync:managed"
}

t_install_foreign_bin() {
  need_stub
  mkdir -p "$HOME/.local/bin"; echo mine >"$HOME/.local/bin/reposync"
  echo '5 5 * * * echo hi' >"$HOME/crontab.txt"; cp "$HOME/crontab.txt" "$T/before"
  _run "$INSTALL"; assert_rc 0
  assert_contains "$OUT" "skip $HOME/.local/bin/reposync: exists and is not ours"
  assert_contains "$OUT" "skip cron: $HOME/.local/bin/reposync is not ours"
  assert_eq mine "$(cat "$HOME/.local/bin/reposync")" "file unchanged"
  [ ! -L "$HOME/.local/bin/reposync" ] || fail "foreign file became a symlink"
  ! wrote || fail "crontab written"
  cmp -s "$HOME/crontab.txt" "$T/before" || fail "crontab changed"
  _run "$UNINSTALL"; assert_rc 0
  assert_eq mine "$(cat "$HOME/.local/bin/reposync")" "uninstall left file"
}

t_install_crontab_l_fails() {
  need_stub
  echo '5 5 * * * echo hi' >"$HOME/crontab.txt"; cp "$HOME/crontab.txt" "$T/before"
  STUB_CRONTAB_FAIL=1 _run "$INSTALL"
  [ "$RC" -ne 0 ] || fail "install should fail"
  assert_contains "$ERR$OUT" "crontab -l failed: crontab: cannot open"
  cmp -s "$HOME/crontab.txt" "$T/before" || fail "crontab changed"
  ! wrote || fail "crontab written"
}

t_uninstall() {
  need_stub
  echo '5 5 * * * echo hi' >"$HOME/crontab.txt"
  _run "$INSTALL"; assert_rc 0
  _run "$UNINSTALL"; assert_rc 0
  assert_eq 0 "$(grep -c '# reposync:managed' "$HOME/crontab.txt")" "managed lines left"
  assert_eq '5 5 * * * echo hi' "$(cat "$HOME/crontab.txt")" "remaining crontab"
  if [ -e "$HOME/.local/bin/reposync" ] || [ -L "$HOME/.local/bin/reposync" ]; then fail "symlink still there"; fi
  [ -x "$REPO_ABS/bin/reposync" ] || fail "repo damaged"
}

t_uninstall_last_line() {
  need_stub
  _run "$INSTALL"; assert_rc 0
  _run "$UNINSTALL"; assert_rc 0
  assert_eq -r "$(tail -n 1 "$HOME/crontab.calls")" "last crontab call"
  [ ! -f "$HOME/crontab.txt" ] || fail "crontab not removed"
}

t_uninstall_no_crontab() {
  need_stub
  _run "$UNINSTALL"; assert_rc 0
  assert_contains "$OUT" "no crontab; nothing to remove"
  ! wrote || fail "crontab written"
}

t_uninstall_no_managed() {
  need_stub
  echo '5 5 * * * echo hi' >"$HOME/crontab.txt"
  _run "$UNINSTALL"; assert_rc 0
  assert_contains "$OUT" "no managed cron line; nothing to remove"
  ! wrote || fail "crontab written"
  assert_eq '5 5 * * * echo hi' "$(cat "$HOME/crontab.txt")" "crontab"
}

t_no_crontab_binary() {
  # PATH = one dir of symlinks; never /usr/bin, /bin or /usr/local/bin (the real crontab is in /usr/bin)
  local mb=$T/minbin c p
  mkdir -p "$mb"
  for c in bash env git ln readlink mkdir dirname basename grep cat rm printf sed tr sort uniq head mktemp; do
    p=$(command -v "$c") && case $p in /*) ln -s "$p" "$mb/$c";; esac
  done
  unset BASH_ENV ENV; PATH=$mb
  [ -z "$(command -v crontab)" ] || fail "crontab visible on minimal PATH"
  _run "$INSTALL"; assert_rc 0
  assert_contains "$ERR$OUT" "crontab not found"
  _run "$UNINSTALL"; assert_rc 0
  assert_contains "$ERR$OUT" "crontab not found"
}
