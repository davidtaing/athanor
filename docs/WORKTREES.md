# Git Worktrees for Parallel Claude Code Sessions

Worktrees let multiple Claude Code sessions work on different branches of
`athanor` at the same time, each in its own directory, without stashing or
branch-switching conflicts.

## Layout: persistent numbered slots

Three persistent worktree slots live as siblings of the main checkout. Each
slot is a stable directory that gets re-pointed at whatever branch is being
worked on — slots outlive branches.

```text
~/athanor          # main checkout   PORT=4000  debugger 4007  athanor_dev
~/athanor-wt1      # slot 1          PORT=4001  debugger 4008  athanor_dev_wt1
~/athanor-wt2      # slot 2          PORT=4002  debugger 4009  athanor_dev_wt2
~/athanor-wt3      # slot 3          PORT=4003  debugger 4010  athanor_dev_wt3
```

Sibling directories keep the main repo clean, but this layout does **not**
rule out other worktrees — agent-managed worktrees (e.g. Claude Code's
worktree isolation, which may nest under `.claude/` or a temp dir) coexist
fine: any directory name that isn't `athanor`/`athanor-wt<N>` gets a
sanitized worktree name and a hashed port in 4100–4999 (see below).

## Per-worktree environment (implemented)

Three shared resources are isolated per worktree, driven by three env vars:

- **`PORT`** — `config/dev.exs` reads it for the Phoenix endpoint
  (default 4000).
- **`LIVE_DEBUGGER_PORT`** — LiveDebugger runs its own endpoint
  (default 4007); `config/dev.exs` reads this for it. `auto_port: true` is
  set as a fallback, so a port clash scans upward instead of crashing.
- **`ATHANOR_WORKTREE`** — `config/dev.exs` and `config/test.exs` suffix the
  database name with it (`athanor_dev_wt1`, `athanor_test_wt1`). The main
  checkout (`ATHANOR_WORKTREE=main` or unset) keeps the unsuffixed names.
  `MIX_TEST_PARTITION` still composes on top for parallel test runs within
  one worktree.

All are derived from the directory name by `bin/worktree-env`, sourced
automatically via the root `.envrc` (direnv):

| directory        | `ATHANOR_WORKTREE` | `PORT`              | `LIVE_DEBUGGER_PORT` |
| ---------------- | ------------------ | ------------------- | -------------------- |
| `athanor`        | `main`             | `4000`              | `4007`               |
| `athanor-wt<N>`  | `wt<N>`            | `4000 + N`          | `4007 + N`           |
| anything else    | sanitized dirname  | hash into 4100–4999 | hash into 5100–5999  |

The fallback row is what keeps agent/nested worktrees collision-free without
any manual assignment.

## First use of a slot

```sh
cd ../athanor-wt1
direnv allow              # once per worktree directory
git checkout -b my-feature origin/main   # point the slot at real work
cd control-plane
mix setup                 # deps + creates/migrates athanor_dev_wt1
```

Each worktree has its own `deps/` and `_build/`, so the first compile per
slot is from scratch. Databases live in the same compose Postgres (5432);
they're just separate database names.

Then start a Claude Code session inside it:

```sh
cd ../athanor-wt1
claude
```

Each session sees its own working tree and branch; commits land on that
worktree's branch. All worktrees share one `.git` object store, so commits
made in one are immediately visible (e.g. for `git log`, cherry-picks,
rebases) from the others.

## Day-to-day commands

```sh
git worktree list                      # show all worktrees and their branches
git worktree remove ../athanor-wt1     # retire a slot (rarely needed)
git worktree prune                     # clean up records of deleted dirs
```

Rules of thumb:

- One branch per worktree — git refuses to check out the same branch twice.
- Slots are persistent: when a branch merges, check out the next piece of
  work in the same slot rather than removing it (`git checkout -b next-thing
  origin/main`).
- The placeholder branches the slots were created with (`wt1`, `wt2`, `wt3`)
  are parking positions, not work branches.
- Rebase/merge from `main` inside the worktree like any normal checkout.
- Drop a stale per-worktree database with
  `psql -h localhost -U postgres -c 'DROP DATABASE athanor_dev_wt1'` if a
  slot's schema gets into a weird state — `mix setup` recreates it.
