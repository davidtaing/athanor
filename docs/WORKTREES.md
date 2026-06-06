# Git Worktrees for Parallel Claude Code Sessions

Worktrees let multiple Claude Code sessions work on different branches of
`athanor` at the same time, each in its own directory, without stashing or
branch-switching conflicts.

## Layout convention

Keep worktrees as siblings of the main checkout, prefixed with the repo name:

```
~/athanor                    # main checkout (main branch)
~/athanor-runner-protocol    # worktree on branch runner-protocol
~/athanor-scheduler          # worktree on branch scheduler
```

Sibling directories (rather than nesting under `athanor/`) keep the main repo
clean and avoid any tooling accidentally recursing into a worktree.

## Creating a worktree

From the main checkout:

```sh
# New branch + worktree in one step
git worktree add ../athanor-runner-protocol -b runner-protocol

# Or check out an existing branch
git worktree add ../athanor-scheduler scheduler
```

Then start a Claude Code session inside it:

```sh
cd ../athanor-runner-protocol
claude
```

Each session sees its own working tree and branch; commits land on that
worktree's branch. All worktrees share one `.git` object store, so commits
made in one are immediately visible (e.g. for `git log`, cherry-picks,
rebases) from the others.

## Day-to-day commands

```sh
git worktree list                          # show all worktrees and their branches
git worktree remove ../athanor-scheduler   # remove when the branch is merged
git worktree prune                         # clean up records of deleted dirs
```

Rules of thumb:

- One branch per worktree — git refuses to check out the same branch twice.
- Remove worktrees once merged; stale ones block `git branch -d`.
- Rebase/merge from `main` inside the worktree like any normal checkout.

## Future: Phoenix server per worktree

Once the Elixir app exists, parallel worktrees will collide on two shared
resources. The plan (not yet implemented):

- **Ports** — each worktree's Phoenix server needs its own port. Read the
  port from an env var in `config/dev.exs`
  (`port: String.to_integer(System.get_env("PORT", "4000"))`) and assign
  each worktree a distinct `PORT` (4000, 4001, 4002, …). LiveReload's
  watcher port will need the same treatment.
- **Databases** — each worktree needs its own dev database so migrations
  and seed data don't fight. Derive the database name from an env var in
  `config/dev.exs` (e.g. `athanor_dev_#{System.get_env("ATHANOR_WORKTREE", "main")}`).
  For tests, `mix test` already isolates via the SQL sandbox, but parallel
  full runs can use `MIX_TEST_PARTITION`.

A per-worktree `.envrc` (direnv) or a small `bin/worktree-env` script can set
`PORT` and `ATHANOR_WORKTREE` automatically from the directory name, so each
Claude Code session picks up the right values without manual setup.
