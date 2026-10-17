# scripts

Reusable personal scripts. Each executable in `bin/` is symlinked into `~/.local/bin` by `install.sh`.

Currently one script: `reposync`, which syncs every git repo directly under the workspace directory with its `origin`.

## Install

```sh
git clone git@github.com:anshulverma/scripts.git ~/workspace/scripts
cd ~/workspace/scripts
./install.sh
```

On a dotsync2 machine this is automatic: `~/.config/dotsync2/post-pull.sh` clones the repo into `$WORKSPACE_DIR/scripts` (`WORKSPACE_DIR` comes from `~/.config/dotsync2/constants.env`) and runs `install.sh`.

First push of this repo (no remote branch exists yet): `git push -u origin main`.

`install.sh` is idempotent and touches only:

- `~/.local/bin/<name>`: a symlink to each file in `bin/`. A file or symlink already there that is not ours is left alone and reported as `skip`.
- Your crontab: one line tagged `# reposync:managed` (see [Cron](#cron)). Other crontab lines are kept. Skipped if `~/.local/bin/reposync` is not our symlink, if `crontab` is missing, or if the line would contain `%`.

It warns if `claude` is not on `PATH` (conflict resolution and commit messages then fall back, see below).

`./uninstall.sh` removes our symlinks and the managed cron line. It keeps the repo and the state directory (`~/.local/state/reposync`, including any rescue files).

## Layout

| Path             | Notes                                                          |
|------------------|----------------------------------------------------------------|
| `bin/reposync`   | the sync script (bash 3.2 compatible)                          |
| `install.sh`     | symlinks `bin/*` into `~/.local/bin`, installs the cron line   |
| `uninstall.sh`   | reverses `install.sh`                                          |
| `tests/`         | `run.sh` runner, `test_*.sh` cases, `lib.sh` helpers, `stubs/` (fake `claude` and `crontab`) |

## reposync

```
usage: reposync [--dirty=skip|commit|keep] [--dry-run] [--workspace DIR] [-h|--help]

Sync every git repo directly under the workspace with its remote.

  --dirty=skip|commit|keep  dirty working trees: skip (default), commit them, or keep (stash around the merge)
  --dry-run                 fetch only; report what would happen
  --workspace DIR           workspace directory
  -h, --help                show this help

Workspace resolution order: --workspace DIR, $WORKSPACE_DIR,
~/.config/dotsync2/constants.env, then $HOME/workspace.

Exit codes:
  0    every repo ok or skipped
  1    any repo failed, or a leftover warning
  2    usage or workspace error
  3    another run holds the lock
  130  interrupted (INT)
  143  terminated (TERM/HUP)
```

For each repo it fetches, then: fast-forwards if behind, merges (`--no-ff`) if diverged, pushes if ahead or diverged, and pushes with `-u` if the branch has no upstream. Up-to-date repos are left alone. Only the current branch of each repo is touched. Only one run at a time (lock in the state directory).

Output is one tab-separated row per repo on stdout: `<repo>  <branch|->  <action>  <result>`. `action` is the steps that completed, joined by `+`, from `committed`, `merged`, `set-upstream`, `pushed` (or `none`). `result` is `ok`, `ok (<note>)`, `skipped:<reason>` or `failed:<reason>`. `--dry-run` fetches with `--no-prune`, changes nothing, prefixes the action with `would-`, and adds a fifth `state` column.

### Dirty modes

| Mode             | Behaviour                                                                                   |
|------------------|---------------------------------------------------------------------------------------------|
| `skip` (default) | A repo with staged, unstaged or untracked (not ignored) changes is skipped (`skipped:dirty`). |
| `commit`         | Commits everything with `git add -A` and a message written by `claude -p --tools ""` from the staged diff (first 500 lines). If claude is unavailable, fails, or returns an empty or over-72-character subject, the message is `reposync: auto-commit from <host> at <ts>`. Hooks and signing run as usual. The result is then synced like any clean repo. |
| `keep`           | Stashes all changes including untracked files as `reposync-keep <ts>`, syncs, then re-applies the stash and drops it only after a clean apply. |

In `keep` mode, if the re-apply conflicts, claude resolves the conflicts. The stash entry is then kept (never dropped), the row says `ok (local changes merged with conflicts; originals kept in <sha>)`, and the run prints `WARN <repo>: leftover reposync stash <sha>` and exits 1. If claude cannot resolve them, the row is `failed:keep-restore (changes in <sha>)` and the stash is kept as well. The stash sha is printed to stderr before any merge. Any `reposync-keep` stash entry left in a repo is reported as a WARN on every later run (including `--dry-run`) until you drop it.

### Skip reasons

`not-git`, `no-origin`, `detached-head`, `no-commits`, `in-progress-op` (merge, cherry-pick, revert, bisect, rebase, or unmerged index entries), `upstream-mismatch` (upstream is not `origin/<branch>`), `dirty` (skip mode), `upstream-gone` (the remote branch was deleted; it is never recreated), `branch-changed` (you checked out another branch while the fetch ran). All checks except `not-git` run again right after the fetch, so a repo you start editing or merging while its fetch runs is skipped too.

### Conflicts

When a merge conflicts, reposync runs `claude -p --dangerously-skip-permissions` inside the repo with a prompt on stdin that lists the conflicted files and forbids git-mutating commands. Timeout: `REPOSYNC_CLAUDE_TIMEOUT` seconds (default 900). Afterwards reposync checks that claude changed nothing but the conflicted files (HEAD, branch, index, stash list, git config, hooks, other branches and tags, other tracked files, untracked files) and that no conflict markers remain. If claude changed other refs, the ref list from before the call is saved as `rescue/<repo>/<ts>/refs.before` (named in the row), because a deleted branch also loses its reflog. Then it commits the merge itself (hooks run) and pushes. Any failed check undoes the merge. Without `claude` or `timeout` (`gtimeout`) the row is `failed:claude-unavailable` and the merge is undone.

### Safety guarantees

- Never `--force` or `--force-with-lease`. Push is always `git push origin HEAD:refs/heads/<branch>`. A rejected push gets one re-fetch, re-merge and retry; a second rejection is `failed:push-rejected`.
- Hooks and signing are never bypassed (no `--no-verify`, no gpg override).
- Uncommitted work is not discarded. On any failure after the first change, one restore routine puts the branch back to where it started:
  - Untracked files created during the run (by the merge, by claude, or by you) are moved, not deleted, to `${XDG_STATE_HOME:-~/.local/state}/reposync/rescue/<repo>/<ts>/`.
  - Tracked edits made during the run are saved as `tracked.patch` in that directory before any `git reset --hard`.
  - In `commit` mode an unfinished auto-commit is undone by restoring the index; a finished one is kept.
  - In `keep` mode the stash is re-applied; a stash that does not apply cleanly is kept.
- Local commits and merges are kept when a push fails.
- If the restore itself cannot reach the expected state, the row is `failed:NEEDS-MANUAL-RECOVERY` with the original commit (and stash sha) printed.
- You can keep working while reposync runs. The start commit is taken after the fetch. Before every push and every reset, reposync checks that HEAD is still on the branch and at a commit it started from or made itself. If you switched branch or committed in between, it stops without pushing, re-pointing or resetting anything. The row is `failed:branch-changed` (a `keep` stash stays and is named), or `failed:NEEDS-MANUAL-RECOVERY (HEAD moved outside reposync; ...)` if the branch is no longer at the start commit. Only a branch switch made by claude is undone.
- Before merging, it refuses (`failed:would-overwrite-ignored`) if the remote would overwrite an ignored or stashed-aside file.
- A repo it cannot handle is skipped or reported as failed. The next repo is still processed.
- Network git calls time out after 300 s (`timeout` or `gtimeout`, if installed). `GIT_TERMINAL_PROMPT=0` and an ssh `BatchMode` default keep cron runs from hanging on a prompt.
- INT, TERM and HUP restore the repo in progress, print the rows so far, and exit 130 or 143.

## Cron

`install.sh` adds this line (paths filled in for your host):

```
17 9 * * * mkdir -p <STATE_DIR> && XDG_STATE_HOME=<STATE_BASE> PATH=<P> ~/.local/bin/reposync > <STATE_DIR>/cron.log 2>&1 # reposync:managed
```

That is daily at 09:17 with the default `--dirty=skip`. The log is `${XDG_STATE_HOME:-~/.local/state}/reposync/cron.log` and is overwritten on every run. `PATH` in the line holds the directories of `git`, `claude` and `node` found at install time, plus the usual system directories, since cron's own `PATH` is minimal. Re-running `install.sh` replaces the line.

## Tests

```sh
bash tests/run.sh            # all cases, prints PASS/FAIL per case, exit 0 iff all pass
bash tests/run.sh dirty      # only cases whose file or function name contains "dirty"
```

Tests use a temp `HOME`, `file://` remotes and stub `claude` and `crontab` programs. No network, no real claude, and the real crontab and `~/.local/bin` are never touched.
