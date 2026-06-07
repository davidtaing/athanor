# Caching for ephemeral CI Runners — research report

**Status:** research input, June 2026. Not an ADR, not a PRD.
**Feeds:** a future grill-why/PRD session on a post-MVP cache for Athanor.
**Frame:** ADR 0003 fixed the shape — one ephemeral Runner per Job, booted by
the Provisioner, destroyed at terminal state; the Runner *is* the sandbox. That
destroy-after model means **a Runner keeps nothing between Jobs by
construction** — every `mix deps.get`, `go mod download`, `npm ci`, and
recompile starts from zero unless something outside the Runner survives. A cache
is precisely that "something outside". This report decides what that something
should be for a single bare-metal host with minio/S3 already in the stack (ADR
0004), Docker-container Runners today, Firecracker later. It deliberately
dovetails with `docs/research/firecracker-runners.md`: that report's per-toolchain
ext4 image store and CoW-clone rootfs are the natural seam a cache hangs off, and
§4 below works that through.

Claims are tagged **[stable]** (architecture/algorithms unlikely to shift) or
**[volatile]** (vendor features, limits, tool maintenance status). Volatile
claims verified against current sources are cited in **Sources**; anything not
verified is marked *(unverified)* inline.

---

## TL;DR recommendations

| Question | Recommendation |
|---|---|
| What to cache first | **Dependency caches only** (`deps/` + `_build/`, Go module + build cache). Highest hit-rate, simplest invalidation. Defer incremental-build and Docker-layer caching. |
| Where to store it | **minio/S3 as tar archives** — the actions/cache model. The `LogStore` blob plumbing from ADR 0004 is 90% of the mechanism; add a `CacheStore` behaviour beside it. |
| Cache key | `{toolchain}-{os}-{hash(lockfile)}` exact key + a prefix `restore-key` for partial hits. Lockfile hash is the invalidation signal. |
| Who moves the bytes | The **Runner** restores on start and saves at end, over HTTP to minio with a presigned URL the control plane mints. Keeps cache bytes off the WebSocket and out of Postgres. |
| Security | **Scope every cache entry to a ref** and never let an untrusted-PR Job *write* the default-branch cache. This is the one non-negotiable; §3 explains why. |
| Firecracker fit | Cache stays an **object-store tar restored into the guest at Job start** — *not* a virtio-blk drive or virtiofs mount. virtiofs is still unsupported in Firecracker [volatile, verified]; a second block device is real plumbing for marginal gain at this scale. |
| Defer | Incremental compiler caches, Docker layer caching, content-addressed stores, attachable block volumes, warm cache volumes. All are post-cache-v1 optimizations chasing a measured miss. |

---

## 1. Cache taxonomy: what actually matters

CI caching is three different problems wearing one word. They differ in hit-rate,
invalidation difficulty, and payoff, and conflating them is the usual way cache
projects overreach.

**Dependency caches — the 80/20 [stable].** The package manager's resolved
downloads and, for Elixir, the compiled deps: `~/.mix`, the project's `deps/`,
and `_build/<env>/lib/<dep>` for Elixir; `$GOMODCACHE` (`~/go/pkg/mod`) and the
Go build cache (`$GOCACHE`) for Go; `node_modules` or the npm/pnpm store for
JS. These are the win because:

- **Hit-rate is high and predictable.** Dependencies change far less often than
  source. Most Pipelines on a branch fetch an identical dependency set.
- **Invalidation is a solved problem.** The lockfile (`mix.lock`, `go.sum`,
  `package-lock.json`) is an exact content fingerprint of the dependency
  closure. Key the cache on its hash and invalidation is automatic and correct:
  lockfile changes → new key → cache miss → refetch. No staleness class exists.
- **The bytes are bounded and worth it.** A `git clone` is fast; `mix deps.get`
  + compiling deps, or a cold `go build` of a dependency tree, is the slow part
  of a cold Runner. This is the cost ADR 0003's destroy-after model re-pays
  every single Job.

For Athanor's own dual-language workload (Elixir control plane, Go runner) this
is the entire near-term need.

**Incremental build caches — high value, hard correctness [stable].** Caching
compiler output keyed on *inputs* so unchanged modules aren't recompiled:
Elixir's `_build` incremental compilation, Go's `$GOCACHE` (already
content-addressed and safe to treat as a dependency-style cache), Bazel/Gradle
action caches, sccache for C/C++/Rust. Payoff is large on big codebases but
correctness is the trap: a stale incremental cache produces a *wrong build* that
still exits 0, which is worse than a slow one. Elixir's `_build` is notoriously
sensitive to compiler/OTP version and timestamp skew across machines. **The safe
subset is the content-addressed ones** (Go's `$GOCACHE`, sccache, Bazel) where a
stale entry is structurally impossible — a changed input is a different address,
so a "stale" entry is simply never looked up. Treat those as dependency caches;
treat timestamp-based incremental state as out of scope.

**Docker layer caches — important elsewhere, mostly N/A here [stable].** Caching
image layers across builds (BuildKit cache mounts, `--cache-from`, registry
cache). This dominates the *hosted CI vendor* conversation (Depot's whole
product is this) because their customers' main job is `docker build`. Athanor's
Jobs run *inside* a Runner that is already a prebuilt image/rootfs; Athanor isn't
in the business of building user Docker images (MVP cut-line: no in-repo YAML, no
artifacts). The closest analogue is **caching the Runner's own base
image/rootfs**, which is the firecracker-runners.md image-store problem, not a
per-Job cache. So Docker layer caching is real but out of frame.

**Verdict:** dependency caches first and possibly only. Content-addressed build
caches (`$GOCACHE`) ride along for free under the same key/store machinery.
Everything else is deferred until a profile says otherwise.

## 2. Vendor practice: what the field converged on

Two dominant models, split by who owns the storage.

**Model A — object-store tar archives (the actions/cache model) [volatile].**
GitHub Actions `actions/cache` is the reference. Shape:

- `save`/`restore` with a **`key`** (exact match) plus **`restore-keys`** (an
  ordered list of *prefixes* for partial hits — restore the nearest, then top
  up). The conventional key embeds an OS tag and a lockfile hash:
  `${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}`.
- A cache entry is a **tarball in blob storage**, uploaded at job end and
  downloaded at job start. Restore = download + untar; save = tar + upload.
- **Branch scoping is a security boundary, not a nicety:** a run reads caches
  from its own branch and from the default branch, but *not* from sibling or
  child branches; the default-branch cache is the shared read pool. A run cannot
  read a cache created by an unrelated branch. (§3.)
- **Limits and eviction [volatile, verified]:** historically 10 GB per repo;
  as of the 2025-11-20 changelog the per-repository cap can now exceed 10 GB
  (configurable, user repos up to 10 TB). Eviction is LRU by last-access, plus a
  hard sweep of anything untouched for **7 days**.

This is the **dominant model for portable, multi-host, untrusted-tenant CI**
because the cache is just blobs — no volume to attach, no host affinity, works
across an autoscaled fleet, and the blob store is the only stateful thing.

**Model B — persistent attached volumes (the "no upload/download" model)
[volatile].** The newer hosted vendors skip tar-over-network entirely by giving
a job a real persistent disk:

- **Depot [verified]:** Docker layer cache + BuildKit cache mounts persisted on
  fast NVMe SSD (50 GB default, to 500 GB) backed by a **Ceph** cluster; the
  project's persistent volume is reattached to a fresh EC2 builder per build.
  No save/load step — the cache is *mounted*.
- **Namespace (namespace.so) [verified]:** NVMe-backed **Cache Volumes**
  mounted directly to the runner, tagged, with a **fork-per-job + last-write-wins
  commit** versioning model — each instance gets a private CoW fork of the most
  recent committed cache version; a clean exit commits a new parent. Concurrent
  readers are safe. This is content-addressed-storage thinking applied to a whole
  volume.
- **Remote build caching (Bazel/sccache/BuildKit registry cache) [stable]:** a
  **content-addressed store** keyed by hashes of build-action inputs, shared over
  the network. Correct by construction (address = content), but it requires a
  build system that models actions as pure functions of inputs — Bazel does,
  `mix`/`go build` mostly don't at that granularity.

**Why the split, and what it means for Athanor:** Model B buys latency (no
tar/upload round-trip) at the cost of **host/volume affinity and a CoW-capable
storage layer** (Ceph, LVM thin pools, NVMe forks). That cost is exactly what a
single bare-metal host with one disk doesn't want to take on yet, and the
affinity it trades for is irrelevant when there's one host. Model A's blob-tar
approach is slower per restore but is **storage Athanor already runs** (minio,
ADR 0004) and is the model whose security properties (branch scoping) are
well-understood. **Athanor should start at Model A and treat Model B's CoW-volume
idea as the same future slice as the firecracker snapshot/warm-pool work** —
both are "make re-boots of the same thing cheap via CoW", both chase a measured
latency problem.

## 3. Architecture options and the security boundary

**Storage shape — three options [stable]:**

1. **Object-store tar archives (Model A).** Download+untar on start,
   tar+upload on end. *Pro:* trivial on top of minio; no host affinity; survives
   Runner destruction by construction. *Con:* pays (de)compression + transfer
   each Job; whole-archive granularity (no partial-file updates).
2. **Attachable block volumes (Model B).** Mount a persistent disk into the
   sandbox. *Pro:* zero copy, lowest latency. *Con:* needs CoW/snapshot storage
   for safe concurrent Jobs, ties a Job to a host, and for Firecracker means a
   second virtio-blk device and its lifecycle (§4). Heavy for one host.
3. **Content-addressed store (CAS).** Store by hash of content/inputs; clients
   fetch only missing objects. *Pro:* dedup across everything, correct by
   construction, partial updates. *Con:* needs a build system or tool that emits
   content addresses (Go's `$GOCACHE` and Bazel do; the broad `deps/` + `_build`
   blob does not). Best as a *targeted* add-on for `$GOCACHE`, not the base.

**Recommendation: option 1 as the base, with `$GOCACHE` as a natural option-3
candidate later.**

**Cache key design [stable].** The key *is* the invalidation policy.

- **Exact key:** `{toolchain-version}-{os}-{purpose}-{hash(lockfile)}` — e.g.
  `elixir-1.18-otp-27-ubuntu-mix-<hash(mix.lock)>`. Include the toolchain version
  because compiled `deps/`/`_build` and `$GOCACHE` are version-specific; a cache
  built under one OTP and restored under another is a subtle corruption source.
- **Restore key (prefix):** `elixir-1.18-otp-27-ubuntu-mix-` — on an exact miss
  (lockfile changed), restore the most recent same-toolchain archive and let the
  package manager top up the delta. Turns a cold miss into a warm miss.
- **Save discipline:** write the exact-key entry only when it doesn't already
  exist (immutable entries; never overwrite a key). This is what makes
  concurrent Jobs safe without locking.

**Security — the part that is not optional [stable].** A CI cache is **attacker-
writable storage that later jobs trust**. The threat is **cache poisoning**: an
untrusted contributor opens a PR whose Job writes a malicious `deps/` or
`node_modules` (or a tampered compiler-output entry) into a cache key that a
*trusted* later Job — especially one on the default branch with deploy
credentials — then restores and executes. This is a documented real-world class
(the "cacheable but untrusted" problem), not theoretical.

Mitigations, in priority order for Athanor:

1. **Ref-scope every entry.** A cache key is namespaced by the ref that wrote it.
   This is *why* GitHub scopes caches to branches and lets only the default
   branch be a shared read pool: a feature branch (or PR) reads the default
   cache but writes only its own. A sibling can't read or poison another's.
2. **Untrusted PRs read but never write the shared pool.** A Job from a fork/
   untrusted ref may *restore* from the default-branch cache (read-only) but must
   write only to a throwaway, ref-scoped namespace that no trusted Job reads.
   Even simpler at MVP scale given the public-repos-only cut-line: **untrusted
   Jobs get no cache write at all.**
3. **Key on the lockfile, not arbitrary input.** Limits what an attacker can
   make the key be.
4. **(Defer) integrity:** signing/hashing entries to detect tampering is a
   content-addressed-store property; out of scope for v1, noted as the hardening
   path.

For Athanor *today* the cut-line makes this cheap: API-triggered, public-repos-
only, no fork-PR concept yet. The discipline to bake in now is **ref-scoped keys
+ a single writable namespace per ref + default-branch-as-read-pool**, so that
when Triggers grow to include untrusted PRs (post-MVP), the boundary already
exists instead of being a retrofit — the same "don't make a model you'll have to
throw away" logic ADR 0003 used.

## 4. Interaction with Firecracker microVM Runners

This is where this report has to agree with `docs/research/firecracker-runners.md`,
which recommends: per-toolchain **ext4 rootfs images built offline from the
existing Docker images**, hard-linked into each VM's jailer chroot, with a
per-Job writable **CoW clone** (`cp --reflink=auto` on XFS/btrfs) for the guest's
writes. A cache has to slot into that without disturbing it.

**Option A — cache as a second virtio-blk drive [stable].** Firecracker attaches
extra block devices via `PUT /drives/{id}`. You could keep a persistent
cache.ext4 and attach it read-write per VM. *Reality check:* concurrent Jobs
can't share one writable ext4 safely, so you'd need a CoW clone of the *cache*
image per Job (the same `reflink` trick the rootfs already uses) plus a
merge-back-on-success step — i.e. you've reinvented Namespace's fork-per-job
volume model on one host. That's real plumbing (drive lifecycle, clone, commit,
GC) for a latency win that's noise next to clone + dependency-fetch on a 10–60 s
Job. **Defer; it's the same CoW-storage slice as snapshots.**

**Option B — virtiofs shared mount from host [volatile, verified].** A host
directory shared into the guest would be the elegant "live cache dir" answer.
**Firecracker does not support virtiofs** — it remains a long-standing,
high-demand-but-unimplemented request (issue #1180); the only filesystem-sharing
path is a virtio **block** device [verified, June 2026]. So virtiofs is *not an
option*, not just deferred. This is the single most important fact for this
section, and it's exactly why the firecracker report lands on block-image rootfs
and why this report lands on object-store tar rather than a shared mount.

**Option C — object-store tar restored into the guest (recommended)
[stable].** The Runner, already running inside the guest with egress (the
firecracker report's TAP + NAT gives it network to reach minio), does
**restore-on-start / save-on-end over HTTP to minio** — identical to the Docker-
Runner path. The guest writes the restored cache into its **CoW rootfs clone**,
which is thrown away with the VM. Nothing about the image store, drive layout,
jailer chroot, or boot path changes. The cache is portable, host-independent,
and reuses ADR 0004's blob plumbing.

**Warm rootfs layers vs cache — keep them separate [stable].** It's tempting to
bake the dependency cache *into* the per-toolchain rootfs image so a booted VM
already has `deps/` warm. Resist it for anything that changes per-Pipeline: the
rootfs image is **shared, read-only, rebuilt offline** (firecracker report §3),
while a dependency cache is **per-project, per-lockfile, frequently invalidated**.
Baking project deps into the toolchain image couples a slow offline image build
to fast-moving lockfiles and breaks the shared-read-only property. The clean
division of labour:

- **Rootfs image** = the *toolchain* (compiler, OTP, base libs) — slow-moving,
  shared, read-only, the firecracker image store's job.
- **Cache tar** = the *project's resolved/compiled dependencies* — fast-moving,
  per-ref, restored at runtime over the network.

What *is* legitimately a "warm layer" is the toolchain itself, and that's already
the firecracker report's recommendation — so the two reports compose: image store
handles the toolchain, `CacheStore` handles the deps, and neither grows a second
block device.

**Net for Firecracker:** the cache design is **packaging-independent** — the same
restore-on-start/save-on-end over minio works for Docker Runners today and
Firecracker Runners later, with zero new virtio devices and zero change to the
ext4 image store. That's the property to preserve.

## 5. Minimal viable cache for Athanor (recommendation)

**Design: object-store tar cache via a `CacheStore` behaviour beside
`LogStore`.**

**Components:**

1. **`CacheStore` behaviour** mirroring ADR 0004's `LogStore`: minio/S3 backend,
   swappable, lives in the same compose stack. Object layout e.g.
   `caches/{ref-namespace}/{key}.tar.zst`. (ADR 0004's blob read/write/seal
   plumbing is most of this; the new part is key/ref namespacing and presigned
   URLs.)
2. **Key derivation in the control plane.** The Definition / Job carries enough
   to compute `{toolchain}-{os}-{hash(lockfile)}` and the ref namespace. The
   control plane mints **presigned PUT/GET URLs** scoped to the allowed keys and
   hands them to the Runner at dispatch.
3. **Restore-on-start / save-on-end in the Runner.** On start: GET the exact key,
   fall back to the newest restore-key prefix, untar into the workspace. On a
   successful Job: tar the dependency paths, PUT to the exact key **only if
   absent** (immutable). Cache bytes go **Runner ↔ minio over HTTP**, never over
   the WebSocket and never into Postgres — same discipline as logs.
4. **Ref scoping from day one.** Writable namespace = the Job's own ref; read
   pool = own ref + default branch. No cross-ref writes. (When untrusted Triggers
   arrive, the boundary is already there.)
5. **Eviction.** Start with a dead-simple time + size sweep on the minio bucket
   (mirror GitHub's 7-day-untouched idea): a periodic control-plane task deletes
   entries older than N days or trims to a byte budget, LRU by last access. No
   need for anything cleverer at one-host scale.

**Why this and not the alternatives:**

- **Reuses ADR 0004 wholesale.** minio is already there; the blob behaviour
  pattern is already there; the "big bytes never touch Postgres / never touch the
  WebSocket" discipline is already a project value. The cache is a second tenant
  of the same idea, which keeps the surface small and the mental model singular.
- **Packaging-independent (§4).** Works for Docker Runners now, Firecracker later,
  unchanged. No second block device, no virtiofs dependency (which doesn't exist),
  no coupling to the ext4 image store.
- **Correct-by-key invalidation.** Lockfile-hash keys mean no staleness class for
  the dependency cache; skipping timestamp-based incremental build state avoids
  the wrong-build-exits-0 trap entirely.
- **Security boundary baked in cheap.** Ref scoping costs one namespace component
  in the key now and saves a painful retrofit when untrusted PRs land.

**What to defer (and why):**

| Deferred | Why / when to revisit |
|---|---|
| Incremental compiler-output caching (timestamp-based `_build`) | Correctness risk > payoff; revisit only with a measured recompile cost and a content-addressed approach. |
| `$GOCACHE`/`$GOMODCACHE` as a separate content-addressed store | Free win but optimization; fold into the same tar first, split out only if Go build time dominates. |
| Docker layer caching | Out of frame — Athanor doesn't build user images (MVP cut-line). |
| Attachable block / CoW cache volumes (Model B) | Needs CoW storage + host affinity; same future slice as Firecracker snapshots/warm pools. Chase a measured restore-latency problem. |
| Cache entry signing/integrity | Hardening for untrusted-PR era; pair with the Triggers-grow work. |
| Compression tuning, partial-file deltas, dedup | Profile first. zstd default is plenty at hobby scale. |

**The one metric to instrument first:** cache **hit-rate** per key prefix and
**restore/save bytes + time**, the same way the firecracker report says to
instrument cold-start before optimizing it. A cache is only worth its complexity
if the hit-rate is high; measure it before reaching for Model B.

---

## What this means (synthesis)

A post-MVP cache for Athanor is a **small, well-bounded addition**, not a new
subsystem. It is ADR 0004's blob pattern pointed at a second kind of payload,
with two pieces of genuinely new thinking: **lockfile-hash cache keys** (the
invalidation policy) and **ref scoping** (the security boundary). Everything
expensive — CoW volumes, content-addressed stores, virtio-blk cache drives,
incremental compiler caches — is deferrable behind the same `CacheStore` seam,
and most of it shares a future slice with the Firecracker snapshot/warm-pool
work. The cache stays packaging-independent on purpose, so the Docker→Firecracker
swap (which the firecracker report already showed is well-bounded) doesn't touch
it. Start with dependency-only tar caches in minio, ref-scoped, keyed on
lockfile hash; measure hit-rate; let the data decide whether Model B is ever
worth its weight.

---

## Sources

- GitHub Actions dependency caching reference & `actions/cache` (docs.github.com,
  github.com/actions/cache): save/restore, `key` + `restore-keys` prefix
  matching, version+branch scoping, default-branch-as-shared-pool, sibling/child
  isolation
- GitHub Changelog: "Actions cache size can now exceed 10 GB per repository"
  (2025-11-20); cache eviction policy enforcement (2025-09-29) — LRU by last
  access + 7-day-untouched sweep
- Depot: "How Depot speeds up Docker builds", "How to use cache mounts…",
  container-builds overview — persistent NVMe (50–500 GB) backed by Ceph,
  reattached per build; BuildKit cache mounts persisted, no save/load
- Namespace (namespace.so): Cache Volumes architecture/storage docs and
  "zero-latency caching" blog — NVMe-mounted Cache Volumes, fork-per-job +
  last-write-wins commit, tag-scoped, concurrent-read-safe
- Firecracker docs & issues (github.com/firecracker-microvm/firecracker):
  "Host Filesystem Sharing" #1180 — **virtiofs unsupported; virtio block device
  is the only fs-sharing path** (status current June 2026); `PUT /drives` for
  extra block devices
- `docs/research/firecracker-runners.md` (this repo) — per-toolchain ext4 image
  store, `docker export` → `mkfs.ext4 -d` pipeline, `cp --reflink=auto` CoW
  rootfs clones, TAP + NAT guest egress
- ADR 0004 (this repo) — `LogStore` behaviour, minio/S3 blob storage, big bytes
  never in Postgres; the pattern this report extends to `CacheStore`
- General/stable: Bazel & sccache remote cache (content-addressed by action
  inputs); BuildKit registry/inline cache; Go `$GOCACHE`/`$GOMODCACHE`
  content-addressing — background knowledge, not version-sensitive

**Unverified, by deliberate choice not to over-fetch:**

- Exact current GitHub Actions per-repo cache cap for *organization*-owned repos
  (configurable; depends on org/enterprise settings) — only the user-repo 10 TB
  and the ">10 GB now possible" change were verified.
- Depot's exact default vs max NVMe figures may drift; cited as 50/500 GB from
  current docs.
- Namespace's GC algorithm specifics beyond "intelligent GC / last-write-wins"
  (marketing-level detail).
- Cache-poisoning specifics are described at the threat-model level (a known,
  documented class); no single CVE/advisory was fetched for this report.
- Any in-progress virtiofs work in a Firecracker branch/roadmap not visible in
  the main issue thread — status reported as "unsupported on main, June 2026".
