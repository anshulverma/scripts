# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Reusable personal scripts. Everything executable lives in `bin/` and is symlinked into `~/.local/bin` by `install.sh`. Today that is `reposync`, which syncs every git repo directly under the workspace (`~/workspace` by default) with its `origin`: fetch, fast-forward or merge, push, with claude resolving merge conflicts. Run daily from cron. See `README.md` for behaviour and flags.

## Layout

- `bin/reposync`: the script. A single bash file.
- `install.sh` / `uninstall.sh`: symlink `bin/*` into `~/.local/bin`; add/remove one crontab line tagged `# reposync:managed`. Both leave foreign files and foreign cron lines alone.
- `tests/`: `run.sh` (runner), `lib.sh` (helpers), `test_*.sh` (cases named `t_*`), `stubs/claude` and `stubs/crontab`.
- Bootstrap: `~/.config/dotsync2/post-pull.sh` (outside this repo) clones this repo into `$WORKSPACE_DIR/scripts` and runs `install.sh`.

## Tests

`bash tests/run.sh [substring]`: exits 0 iff every case passes. The substring matches a file or case name. Run it before every commit. Also run `bash -n` and `shellcheck` on `bin/reposync`, `install.sh`, `uninstall.sh` and `tests/*.sh`.

## Conventions

- bash 3.2 (macOS): no `declare -A`, `mapfile`/`readarray`, `${v,,}`, `wait -n`, `|&`. No `sed -i`, `readlink -f`, `grep -P`. ISO time is `date -u +%Y-%m-%dT%H:%M:%SZ`.
- All shell files pass `bash -n` and `shellcheck`.
- Never `--force` or `--force-with-lease`, never a bare `git push`, never `--no-verify`, never override gpg. Push is `git push origin HEAD:refs/heads/<branch>`.
- Never lose uncommitted changes. Anything reposync removes from a working tree is moved to `$STATE_DIR/rescue/` first, and a `reposync-keep` stash is dropped only after a clean apply. Never `git reset` with an empty target.
- `GIT_OPTIONAL_LOCKS=0` is exported, so `git status` on a skipped or dry-run repo never rewrites the user's index.
- Tests use `file://` remotes and a temp `HOME` only. No network. `claude` and `crontab` are the stubs in `tests/stubs`, first on `PATH`. Tests never touch the real crontab or the real `~/.local/bin`. They run reposync from the temp dir, never from this repo, and always pass `--workspace`.
- To add a script, drop it in `bin/` and re-run `./install.sh`.
- The first push of this repo is `git push -u origin main`.

## Things that are easy to get wrong

- Prompts to claude go on stdin from a file, never argv. Never let claude inherit the repo loop's stdin (it would eat the rest of the input). `claude` runs with `CLAUDECODE` unset and `GIT_ALLOW_PROTOCOL=none`.
- Every network git call and every claude call goes through `run_child` (background plus `wait`, never `$(...)` or a foreground call). Otherwise the INT/TERM trap does not fire until the child exits.
- There is one `restore` routine, used by every failure after the first mutation and by the signal trap. It relies on `PRE` (the commit the branch must return to; set after the fetch, once the branch and skip checks have been re-run, and moved forward after a successful commit, ff-merge or before a push so that local commits survive) and `SNAP_TAKEN` (only then are untracked files rescued and `reset --hard` allowed). Change those two invariants carefully; do not add a second recovery path.
- The user may work in a repo during a run. `foreign_head` decides whether HEAD is somewhere reposync put it (on B at PRE, RS after a fast-forward, the PRE+RS merge, or the auto-commit on PRE). When it is not, every push refuses (`failed:branch-changed`, no restore) and restore touches nothing (`failed:branch-changed`, or `NEEDS-MANUAL-RECOVERY` if B is no longer at PRE). Restore re-points or resets a moved HEAD only when `CLAUDE_MOVED=1`, i.e. HEAD or the branch changed across a claude call. Any new long-running step (network, claude, hooks) followed by a destructive one needs the same check.
- Stash identity is by sha (`STASH_SHA`), never by `stash@{0}`. The stash entry is found by sha when dropping, and a leftover entry is recognised by its `reposync-keep` subject.
- Never use `@{u}` or `@{upstream}` for upstream checks. It fails when `origin/<branch>` is gone, which would turn a deleted remote branch into "no upstream" and recreate it. "Upstream configured" means `git config --get branch.<B>.merge` succeeds.
- `--dry-run` fetches with `--no-prune`. With `fetch.prune=true` a plain fetch would delete the remote-tracking ref, and the next real run would push the branch back to the remote.
- Conflicted paths are read NUL-safe (`git diff -z --name-only --diff-filter=U`) and staged per path with `--literal-pathspecs`. Repo names, branch names (`feature/x`) and file names may contain spaces or non-ASCII, so quote every path.
- After claude resolves a conflict, reposync verifies git state itself (HEAD, MERGE_HEAD, branch, stash list, index, config, hooks, other refs, untracked files, no conflict markers) and makes the commit. Do not trust claude to commit. If claude changed other refs, their before-list is saved as `rescue/<repo>/<ts>/refs.before` (a deleted branch loses its reflog).
- Repo detection compares `--show-toplevel` with the physical path (`cd -P`), so a `--workspace` that is a symlink still works and a plain directory inside another repo is not mistaken for one.
- Rows go to stdout (one per repo, plus `WARN` lines). The report goes to stderr and `$STATE_DIR/report.log`. Every row goes through `emit_row` and every warning through `leftover_warnings`, so the report and its counts stay complete; route any new row or warning through them too. `ERRF` is truncated per repo and holds the stderr of that repo's failed `run_child` calls. Exits after `parse_args` go through `fatal` so that the reason shows up in the report.
- The cron line must not contain `%`. `install.sh` skips cron if a path does.
