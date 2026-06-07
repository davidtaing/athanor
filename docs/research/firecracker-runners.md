# Firecracker microVMs as ephemeral CI Runners — research report

**Status:** research input, June 2026. Not an ADR, not a PRD.
**Feeds:** a future grill-why/PRD session on the Firecracker Provisioner, and
the "remote runner-host Provisioner" slice named as the trigger for parked
issue #39.
**Frame:** ADR 0003 already decided the shape — one ephemeral Runner per Job,
booted by a Provisioner, destroyed at terminal state; the Runner *is* the
sandbox. Firecracker swaps the Runner's packaging (Docker container → microVM)
behind the same Provisioner behaviour. Nothing in the Runner protocol
(Phoenix Channels over WebSocket, Boot Token at first join) needs to change;
this report is about what the swap costs and how to do it.

Claims verified against current sources are cited in **Sources**; anything
that couldn't be verified is marked *(unverified)* inline.

---

## TL;DR recommendations

| Question | Recommendation |
|---|---|
| Integration surface | Drive the Firecracker HTTP API directly over its Unix socket from the Elixir Provisioner. Skip firecracker-go-sdk, firecracker-containerd, ignite, flintlock. |
| Isolation | Use `jailer` from day one — it's cheap to adopt early and is the production-isolation story. |
| Guest kernel | Start with Firecracker's CI-prebuilt kernels (S3); build from their `resources/guest_configs/` only when curiosity demands. |
| Rootfs | `docker export` → `mkfs.ext4 -d` pipeline: the existing runner Docker image converts mechanically. Static Go runner binary baked in, tiny init. |
| Boot Token injection | Kernel cmdline for the first cut; MMDS V2 as the cleaner follow-up. |
| Networking | Per-VM TAP + point-to-point /30 + nftables MASQUERADE; guest IP via `ip=` boot arg. No bridge. |
| Boot strategy | Cold boot (~125 ms to guest userspace; clone + toolchain dominate anyway). Snapshot-restore is a later learning slice, not MVP-of-the-swap. |
| Ops | Host is ready (KVM, cgroups v2). The real work is that the Provisioner owns *all* cleanup: process, TAP, nft rules, chroot dir — plus an orphan sweep at startup. |

---

## 1. Integration surface: drive the HTTP API directly

Firecracker is configured over a REST API on a Unix domain socket: a handful
of `PUT` calls (`/boot-source`, `/drives/...`, `/network-interfaces/...`,
`/machine-config`, optionally `/mmds`) followed by
`PUT /actions {"action_type": "InstanceStart"}`. That's the entire integration
surface for boot-one-VM-per-Job. The upstream project is healthy: v1.16.0
shipped 2026-06-04.

The ecosystem above that API, however, has thinned out:

- **firecracker-go-sdk** — last tagged release is v1.0.0 from September 2022;
  commits continue (latest December 2025) but they're maintenance-grade. It's
  a Go library, and Athanor's Provisioner is Elixir — using it would mean a Go
  sidecar process just to translate JSON into JSON.
- **firecracker-containerd** — actively maintained (pushed May 2026), but it
  exists to run *container workloads* under containerd with microVM isolation.
  It drags in containerd, a snapshotter, and an in-guest agent protocol —
  heavy machinery for "boot one VM, run one Job, destroy it", and it would own
  the lifecycle that ADR 0003 says the Provisioner owns.
- **weaveworks/ignite** — archived (Weaveworks shut down in early 2024). Dead.
- **flintlock** (weaveworks-liquidmetal) — repo no longer reachable via the
  GitHub API; effectively defunct *(exact disposition unverified)*.

**Recommendation:** the Provisioner execs `jailer` (which execs `firecracker`)
via a supervised port, then speaks the API directly over the Unix socket —
Mint/Finch handle `{:local, path}` sockets natively. This keeps the whole
boot/destroy lifecycle in the Elixir Provisioner behaviour where ADR 0003 put
it, and the API surface is small enough that a client is an afternoon, not a
project.

**Trade-off:** you own process supervision, socket lifecycle, and cleanup
yourself instead of delegating to an SDK's `Machine` abstraction. For a
learning project whose stated purpose is understanding exactly this
coordination, that's the point, not a cost. If a Go-side helper ever becomes
attractive (e.g. for the remote runner-host slice), the go-sdk is usable but
quiet — treat it as a convenience, not a foundation.

## 2. Jailer: use it from day one

`jailer` is Firecracker's production wrapper: it chroots the VMM into a
per-VM directory, moves it into new namespaces (PID, and optionally a network
namespace), applies cgroup limits, and drops from root to a dedicated
unprivileged uid/gid before exec'ing `firecracker`. Firecracker itself then
applies its seccomp filters. AWS's own production guidance is jailer + one
uid/gid pair per VM.

Per-VM setup the Provisioner does:

1. Create `/srv/jailer/firecracker/{vm-id}/root/` (jailer's chroot base).
2. Hard-link (not copy) the kernel and rootfs images into the chroot — fast
   and disk-cheap, but it requires the image store and the chroot base to live
   on the same filesystem. The rootfs link must point at a per-VM *copy* or
   CoW clone if the guest writes to it (see §3).
3. Run `jailer --id {vm-id} --uid {uid} --gid {gid} --exec-file firecracker ...`.
   The API socket appears inside the chroot at a fixed relative path.
4. On destroy: kill the process, then remove the chroot dir (§7).

**Why day one and not later:** running bare `firecracker` as your login user
works and is tempting for a first boot, but jailer changes the filesystem
layout (chroot-relative paths for kernel/rootfs/socket) and the privilege
model (something must run as root to start it). Retrofitting those into a
Provisioner that assumed flat paths and one uid is exactly the kind of rework
ADR 0003 rejected when it skipped the daemon-runner model. The incremental
cost of starting jailed is one directory convention and a sudo rule.

**Single-host honesty:** jailer + seccomp + KVM is strong isolation for
running untrusted Job code, far beyond a Docker container's shared kernel.
What it does not give you on one mini PC is blast-radius isolation from the
control plane — host kernel bugs, disk exhaustion, and conntrack are still
shared. That's inherent to single-host and fine at this scale; the remote
runner-host slice (issue #39's trigger) is where that boundary would move.

## 3. Guest images: kernel, rootfs, and getting the toolchain in

**Kernel.** Firecracker validates specific guest kernel series (currently
5.10 and 6.1) with configs published in the repo at `resources/guest_configs/`.
Their CI also publishes prebuilt kernels to S3
(`https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/...`) — the same
artifacts their own test suite boots. **Start there.** Building from their
config (`make vmlinux`, uncompressed ELF on x86_64) is a well-trodden path
when you want to own it, but it's not on the critical path of the swap.

**Rootfs.** The canonical pattern, straight from Firecracker's own docs:

```sh
docker create <image>            # any existing Docker image
docker export <cid> | tar -C rootfs-dir -x
mkfs.ext4 -d rootfs-dir -F rootfs.ext4   # pack a directory into raw ext4
```

This is the key economic fact of the whole migration: **the existing runner
Docker image — toolchains and all — converts to a Firecracker rootfs
mechanically.** "How do I get Docker-image-equivalent toolchains into the
guest" dissolves into "keep building toolchain images with Docker, add an
export step." One ext4 image per supported toolchain image, built offline,
hard-linked into each VM's chroot at boot. The guest writes (clone dir, build
artifacts), so each Job needs its own writable instance: at hobby scale,
`cp --reflink=auto` on an XFS/btrfs image store is the simple answer; Fly.io's
LVM thin-pool CoW snapshots are the same idea at fleet scale.

Third-party OCI→rootfs converters exist (vmsan, buildfs, ignite's old
approach) but none is dominant or guaranteed alive; the four-line pipeline
above is transparent and dependency-free. *(Tool longevity unverified —
deliberately not load-bearing.)*

**Init and the runner binary.** PID 1 must mount `/proc`, `/sys`, `/dev`, set
up loopback, and never exit. Alpine + OpenRC is the documented reference, but
for a single-purpose Runner a ~50-line static init (or the Go runner itself as
PID 1, doing its own mounts) is entirely valid and more in the spirit of "the
Runner *is* the sandbox". The runner builds static (`CGO_ENABLED=0`) and gets
copied into the rootfs at image-build time.

**Boot configuration injection.** Today the Docker Provisioner injects the
Boot Token and control-plane URL as env vars. Equivalents, in increasing
order of polish:

1. **Kernel cmdline** (`boot_args`) — visible in `/proc/cmdline`; a few
   hundred bytes; available before any filesystem mounts. Sufficient and
   honest for the first cut: the Boot Token is one-time and already burned by
   the time any Job Step runs, so cmdline visibility inside the guest is not a
   leak in this design.
2. **MMDS V2** — Firecracker's metadata service: the Provisioner `PUT`s a JSON
   document pre-boot; the guest fetches it from a link-local address with a
   session token (V1 is deprecated). This is the designed-for-credentials
   path and the natural home for the Boot Token once cmdline feels crude.
3. **vsock** — full host↔guest RPC channel (what firecracker-containerd uses).
   Overkill here: the Runner already has a perfectly good channel to the
   control plane — the WebSocket.

## 4. Networking: TAP + /30 + NAT, no bridge

Firecracker's network model is one TAP device per VM on the host, wired to
the guest's virtio-net `eth0`. The official docs recommend **per-VM
point-to-point /30 subnets with NAT masquerade** for egress-only workloads —
which a CI Runner is — over a shared bridge, which would give Runners
lateral visibility to each other and the LAN.

Per-VM host setup (Provisioner-owned, index `N` allocated per boot):

```sh
ip tuntap add tap{N} mode tap
ip addr add 172.16.{N}.1/30 dev tap{N}
ip link set tap{N} up
# once, at host setup: sysctl net.ipv4.ip_forward=1 (persisted)
# nftables: masquerade 172.16.{N}.0/30 out the uplink; forward tap{N}<->uplink
```

Guest side needs **zero userspace network tooling** — the kernel configures
the interface from a boot arg:

```text
ip=172.16.{N}.2::172.16.{N}.1:255.255.255.252::eth0:off
```

With masquerade up, the guest can clone public repos and reach the control
plane. Two routes to the control plane on the same host: the host end of the
TAP (`172.16.{N}.1`, per-VM) or the host's LAN address (stable across VMs —
simpler to template into the boot config). DNS is not automatic: bake
`/etc/resolv.conf` into the rootfs.

Gotchas, all small at this scale: `ip_forward` defaults off on Ubuntu and the
`/proc` write doesn't survive reboot; MTU is a non-issue on a standard
1500-byte bare-metal uplink; conntrack exhaustion is a hundreds-of-VMs
problem, not a one-mini-PC problem; **TAP devices and nft rules outlive the
firecracker process and must be deleted explicitly** (§7).

## 5. Boot latency and snapshots: cold boot is fine

- Official figure: **~125 ms** from VMM start to guest userspace, <5 MiB VMM
  memory overhead per microVM (firecracker-microvm.github.io).
- Real Job latency is dominated by everything *after* boot: runner start,
  WebSocket join, `git clone`, dependency fetch. The VM boot is noise next to
  a 10–60 s Job. The existing 60 s boot timeout (boot call → first join, per
  the runner protocol spec) is ample headroom.
- ADR 0003 made cold-start a first-class metric — instrument it
  (boot→first-join is already observable from existing timestamps) before
  optimizing it.

**Snapshots** are the optimization vendors reach for, and they're genuinely
interesting — but they're a separate learning slice, not part of the swap:

- Full snapshots are production-ready; **diff snapshots are still developer
  preview**. No official latency figures are published — the docs say
  restore cost scales with memory/vCPU/device count and warn that **cgroups
  v1 hosts suffer high restore latency** (cgroups v2 recommended; this host
  is already v2).
- Restored VMs are clones: **network state is not preserved** (each clone
  needs its own TAP and, per the docs, a network namespace), and **entropy/
  unique-ID duplication** is a real hazard (mitigated by VMGenID on guest
  kernels ≥5.18). Session-state hazards don't bite Athanor's design — the
  Runner joins *after* boot, so a snapshot taken pre-join contains no
  credentials — but the plumbing is real work.
- CodeSandbox demonstrates the ceiling: ~2 s forks of multi-GiB running VMs
  via `userfaultfd` lazy page loading. Impressive, and aimed at a problem
  (resuming stateful dev environments) Athanor doesn't have.

**Recommendation:** cold boot per Job. Snapshot-resume of a post-boot,
pre-join Runner image is a well-shaped future experiment — it's ADR 0003's
"warm pools are a Provisioner concern" made concrete — but it should chase a
measured latency problem, not precede one.

## 6. How real platforms do it

**Fly.io** — one Firecracker VM per app instance, booted from customer OCI
images. Their pipeline: registry pull → unpack layers → block device, later
upgraded to containerd + **LVM2 thin-provisioned CoW snapshots** so VMs
sharing a base image share unwritten blocks. Custom Rust init reads a
host-injected config blob, sets up DNS, launches the workload. TAP devices
with BPF/XDP filters per VM; lease-based GC frees dead VMs' storage. The
lesson for Athanor is the rootfs economics: image-to-blockdev conversion is
the engineering surface, and CoW cloning is how re-boots of the same image
get cheap.

**CodeSandbox** — one VM per sandbox; the product *is* VM cloning. Shared
read-only rootfs loop device + per-VM CoW overlay; memory via Firecracker
snapshots restored lazily through `userfaultfd`, so only touched pages load —
~2 s forks of 4–12 GiB VMs. The advanced end of the snapshot spectrum; useful
as a map of where the road goes, not as a starting point.

**GitHub Actions** — hosted runners are **full Azure VMs, not Firecracker**
*(architecture widely documented; not confirmed via a first-party
architecture post)*: one VM per Job from prebuilt images, 30–60 s cold
provision, destroyed after. Validation that VM-per-Job with destroy-after is
the industry-standard isolation granularity — exactly ADR 0003's model — and
that it tolerates far worse boot latency than Firecracker's.

**Namespace (namespace.so)** — sells "fully isolated fast-booting instances"
per CI job on their own bare metal; mechanism (Firecracker vs other
KVM-based, snapshot vs warm pool) is not public *(unverified)*. Depot and
BuildKite hosted agents similarly publish outcomes, not architecture.

**Pattern across all of them:** one VM per unit of untrusted work, destroyed
after; rootfs comes from an OCI-image conversion pipeline; speed comes from
CoW storage and snapshot/restore, added later, behind the same lifecycle.
Athanor's Provisioner behaviour is already the right seam for that evolution.

## 7. Operational gotchas

**Host readiness — already verified on this machine** (checked while writing
this report): kernel 6.17-generic, `/dev/kvm` present (`kvm` group; the
Provisioner's user needs membership or an ACL), cgroups v2. Firecracker's
officially *validated* host kernels are currently 6.1 and 6.18 (v1.16.0 added
6.18; each series gets ≥2 years of support) — 6.17 isn't in their CI matrix
but intermediate kernels routinely work; the matrix is what they test, not a
compatibility cliff. Re-run the same three checks (`uname -r`,
`ls -l /dev/kvm`, `stat -fc %T /sys/fs/cgroup`) on the runner host if it's a
different box.

**Resource sizing.** Per-VM `machine-config` is just `vcpu_count` +
`mem_size_mib`. With <5 MiB VMM overhead, the budget is essentially
guest RAM × concurrent Jobs + headroom for Postgres/BEAM. A mini PC
comfortably runs a handful of 1–2 vCPU / 1–2 GiB Runners; CPU overcommit is
fine for bursty CI workloads, memory overcommit is the thing to be conservative
about. Concurrency limits stay where they already live — the Scheduler/
Provisioner — not in Firecracker.

**Cleanup/reaping is the real operational surface.** Killing the firecracker
process reclaims guest memory, but **everything else leaks by default**:

| Resource | Cleanup |
|---|---|
| firecracker/jailer process | SIGKILL is safe — state is Postgres + S3 (ADR 0002/0004); the VM is disposable by design |
| TAP device | `ip link del tap{N}` — persists after process exit |
| nftables rules | delete the per-VM rules (or use one static rule over an aggregate like `172.16.0.0/16` and skip per-VM rule churn) |
| jailer chroot dir | `rm -rf` (per-VM rootfs copy lives here) |
| cgroup | remove the per-VM cgroup dir |

The destroy path is already fire-and-forget idempotent in the protocol design
(`job:finished` re-drives destroy on duplicates); the Firecracker Provisioner
must make each of these steps individually idempotent the same way. And
because the Provisioner can die between boot and destroy, it needs an **orphan
sweep at startup** — which is only safe if boot bookkeeping persists a
**deterministic host-resource↔Runner identity contract**: the concrete
handles (TAP device name, chroot path, cgroup path, VMM PID and API-socket
path) recorded on the Runner row as boot creates each one. This is ADR 0002
applied to host resources — Postgres owns the truth, including the truth
about which TAP belongs to which Runner. The sweep then enumerates host
resources (`tap*` devices, jailer chroot dirs, per-VM cgroups) and reconciles
each against those exact persisted keys — never name-pattern heuristics:
destroy anything with no owning row or whose Runner is terminal; skip
anything keyed to a live Runner. Without the persisted handles, a
restart-time sweep can reap a live VM or miss a leaked one whose name
drifted. This is the same deadline-sweep philosophy the Scheduler already
uses, applied to host resources, and it's a genuinely interesting slice of
the coordination problem this project exists to explore.

---

## What this means for the Provisioner design (synthesis)

The swap is well-bounded. Unchanged: the Runner protocol, Boot Token
lifecycle, Job state machine, scheduler, and the Provisioner behaviour's
contract. Changed: the behaviour's implementation, which grows from "ask
dockerd" into five concrete responsibilities —

1. **Image store**: per-toolchain ext4 rootfs built offline from the existing
   Docker images, plus one CI-prebuilt kernel.
2. **Boot**: allocate index N → TAP + /30 → chroot + hardlinks + rootfs copy →
   jailer exec → configure over the API socket → InstanceStart, with the Boot
   Token on the kernel cmdline (later MMDS) — persisting each host handle
   (TAP name, chroot path, cgroup path, PID/socket path) on the Runner row as
   it is created.
3. **Destroy**: the idempotent five-row cleanup table above, driven by the
   persisted handles.
4. **Orphan sweep** at startup, reconciling enumerated host resources against
   the persisted handles by exact key (§7).
5. **Cold-start instrumentation** (boot→first-join), which then decides
   whether the snapshot/warm-pool slice is ever worth building.

Docker hid 2–4 behind one daemon; doing them explicitly is the Firecracker
learning content. None of it requires new protocol surface, new state-machine
states, or Go-side changes beyond possibly serving as PID 1.

---

## Sources

- Firecracker docs (github.com/firecracker-microvm/firecracker, `docs/`):
  getting-started, network-setup, rootfs-and-kernel-setup, kernel-policy
  (host/guest support tables), snapshotting/snapshot-support, MMDS user guide
- firecracker-microvm.github.io — 125 ms boot, <5 MiB overhead, density claims
- GitHub API release/activity data (June 2026): firecracker v1.16.0
  (2026-06-04); firecracker-go-sdk v1.0.0 (2022-09-07, commits through
  2025-12); firecracker-containerd (active, pushed 2026-05); weaveworks/ignite
  (archived)
- Fly.io: "Docker without Docker", "Sandboxing and Workload Isolation"
  (fly.io/blog)
- CodeSandbox: "How we clone a running VM in 2 seconds",
  "Cloning microVMs using userfaultfd", "Scaling microVM infrastructure using
  low-latency memory decompression" (codesandbox.io/blog; partially via
  search snippets — deep pages 403'd at fetch time)
- Practitioner write-ups: hans-pistor.tech "Networking with Firecracker";
  blog.0x74696d.com "Networking for a Firecracker Lab"; felipecruz.es
  "Exploring Firecracker microVMs for multi-tenant Dagger CI/CD pipelines"
- namespace.so/docs/architecture/compute (marketing-level only)

**Unverified, by deliberate choice not to over-fetch:** flintlock's exact
disposition; Namespace's virtualization mechanism; GitHub Actions' Azure-VM
architecture via a first-party post; official snapshot-restore latency
figures (none published); third-party OCI→rootfs tool longevity.
