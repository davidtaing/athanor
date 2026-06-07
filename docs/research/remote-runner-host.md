# Remote runner-host coordination — research report

How a CI control plane on one machine coordinates a **runner host** on another:
job dispatch direction, host registration, the failure modes that only appear
once the wire crosses a network, where the Provisioner splits across hosts, and
which transport an Elixir-first developer should reach for first.

Companion to ADR 0003 (ephemeral Runners), `docs/supervision-tree.md`
(singleton Scheduler, Task.Supervisor Provisioner, deadlines-as-columns,
fire-and-forget destroy), `docs/research/firecracker-runners.md` §7 + synthesis
(the five Provisioner responsibilities), and the parked issue #39
(orphan-container reconciliation, which this report's failure-mode section is
the trigger for). Glossary terms (Runner, Provisioner, Scheduler, Job, Boot
Token, Session Token) are used exactly as in `CONTEXT.md`.

**Scope note on auth:** this report names the registration/credential seam but
deliberately does **not** design it. A separate machine-auth research session
owns the mechanism (per-host identity, rotation, revocation). Here we describe
vendor practice and mark the boundary.

> **A vocabulary caution.** Every product surveyed below calls its host-side
> process an "agent" or "worker" — a *long-lived* daemon that registers once and
> serves many jobs. Athanor's `CONTEXT.md` reserves **Runner** for the
> ephemeral, one-Job sandbox and forbids "agent". These are not the same actor.
> When this report says a vendor's "agent registers with the control plane", the
> Athanor analogue is the **Provisioner's host-side half**, *not* the Runner.
> The Runner in Athanor never registers a long-lived connection with the
> control plane on its own behalf — it joins once, with a Boot Token, for the
> duration of one Job. Keeping this straight is the whole point of question 4.

---

## TL;DR recommendations

1. **Build a host-local provisioner daemon (option 4b), not SSH-from-control-plane
   and not a queue-pulling agent.** It is the only split that keeps Athanor's
   *existing* coordination model intact — Postgres stays the source of truth, the
   Scheduler stays the singleton dispatcher, deadlines stay columns — while
   moving exactly the five firecracker-host responsibilities (image store, boot,
   destroy, orphan sweep, cold-start instrumentation) to where the hardware is.
2. **Speak HTTP/WebSocket to it, in Go, not distributed Erlang.** You already
   proved the WS pattern with the Phoenix-Channels Runner protocol (ADR 0001);
   reuse the muscle. Dist-Erlang's "join the cluster and you have a shell"
   trust model is the wrong default for a box whose whole job is running
   untrusted customer code.
3. **The control plane keeps initiating** (control-plane → host), unlike the
   surveyed vendors who are agent-initiated — and that is *fine at your scale*
   and worth understanding as a deliberate inversion (see §1, §6). One host you
   own, on a private network, is the case where push is acceptable.
4. **Orphan reconciliation (#39) ships with this slice, not after.** Once
   destroy crosses a network, force-destroy failing is routine, not a narrow
   window. The startup orphan sweep from the firecracker synthesis becomes a
   *periodic* reconcile keyed on terminal Runner records.
5. **Defer:** a second host, host-initiated/outbound-only dispatch, mutual TLS
   beyond the WireGuard tunnel, and warm pools. Build the one-host push model
   first; the inversion to pull is a contained, well-understood change when a
   second host or a hostile network actually arrives.

---

## 1. Pull vs push: how the industry dispatches work

All four surveyed systems are **agent-initiated (outbound-only)**: the host-side
process opens the connection *to* the control plane and asks for work. None of
them let the control plane dial in to the host. The mechanism differs; the
direction does not.

| System | Host process | Registration | Work acquisition |
|---|---|---|---|
| **GitHub Actions self-hosted** | runner app (long-lived) | registration token → exchanges for per-runner creds | **HTTP long poll**, ~50 s connection; job assigned to an idle matching runner; re-queued if not picked up in 60 s *(verified)* |
| **GitLab Runner** | `gitlab-runner` daemon | `glrt-` authentication token (replaced the old registration-token flow) | `POST /api/v4/jobs/request`; Workhorse holds the request open (Redis PubSub long poll) and releases it when the runner's key changes or the poll window elapses *(verified)* |
| **Buildkite agent** | `buildkite-agent` daemon | agent token → exchanged at start for a **session token**; per-job **job token** minted on accept | agent **polls** the platform for work; `--acquire-job` self-assigns one specific job and exits *(verified)* |
| **Woodpecker / Drone** | agent/worker daemon | shared `AGENT_SECRET` → server mints an agent ID stored to a file, reused on reconnect | agent **pulls** from the server's queue over a **gRPC stream** (port 9000) *(verified)* |

**Why the industry converged on outbound-only.** The connection direction is a
*security and operability* decision, not a performance one:

- **Firewall/NAT asymmetry.** Runner fleets live behind NAT, in customer VPCs,
  on laptops. Requiring inbound reachability to every runner is operationally
  impossible at fleet scale. Outbound-443 works everywhere. (GitHub states this
  explicitly: "There is no need for an inbound connection… GitHub does not
  connect directly to your VM." *(verified)*)
- **Blast radius.** The control plane is the high-value, hardened, well-known
  target. The runner box runs untrusted customer code and is assumed
  compromisable. You want the *untrusted* side to initiate to the *trusted*
  side, never the reverse — an inbound control channel on the runner host is an
  attack surface on the machine you least trust.
- **Backpressure for free.** Pull means a saturated agent simply stops asking.
  The control plane never has to model agent capacity or risk pushing a job at a
  busy or dead worker; "who's free" is answered by "who asked".
- **Long-poll, not busy-poll.** The naive cost of pull — latency and request
  spam — is erased by long polling (hold the request open server-side until work
  exists or a timeout fires). GitLab and GitHub both do exactly this; it is
  pull's latency with push's responsiveness. *(verified)*

**What push-based designs give up.** A control-plane-initiated design (dial the
host, hand it a job) gives up all four advantages above: it needs inbound
reachability to the host, it puts a control channel on the untrusted box, it
must *track* host capacity itself rather than reading it from who-asked, and it
must handle the host being unreachable as an active error rather than a silent
non-poll. **It buys, in return, simplicity for exactly one topology: a small,
fixed set of hosts you own on a network you control** — which is precisely
Athanor's case (§6). The reason push is "wrong" at vendor scale is the reason it
is *acceptable* at hobby scale: the assumptions that break it (NAT, fleets,
untrusted networks, dynamic membership) are assumptions Athanor doesn't have on
day one.

---

## 2. Host registration and credentials — vendor practice only (seam, not design)

Across the survey there is a consistent two-token shape, and it is worth naming
because it **rhymes with Athanor's existing Boot Token / Session Token split**
(`CONTEXT.md`) — but operates at a different layer.

- **Long-lived registration/auth credential** identifies the *host* (or host
  pool) to the control plane: GitHub's registration token, GitLab's `glrt-`
  authentication token, Buildkite's agent token, Woodpecker's `AGENT_SECRET`.
  These prove "this machine is allowed to be a worker here."
- **Short-lived session credential** is minted at connect and scoped to the
  connection or the job: Buildkite's session token (agent lifetime) and job
  token (one job); GitLab and GitHub exchange the registration credential for
  per-runner/per-job credentials internally. *(verified for Buildkite/GitLab/GitHub)*
- **Identity persistence across reconnect.** Woodpecker mints an agent ID on
  first contact and the agent stores it to a file, presenting `secret + ID`
  thereafter *(verified)* — a per-host identity that survives restart without a
  human re-registering.
- **Rotation / revocation** in vendor practice is "revoke the long-lived token
  server-side; the host's next poll fails." Tokens are revocable from the
  control plane's UI/API; rotation is reissue-and-redeploy.

**The Athanor seam.** Athanor's `Boot Token` / `Session Token` pair authenticates
a *Runner* (the ephemeral one-Job sandbox), not the *host*. The remote
runner-host introduces a **new, distinct credential layer**: how the
**host-side provisioner daemon** authenticates to the control plane. That is the
machine-auth question, and **this report stops here on purpose.** The dedicated
machine-auth session owns: per-host identity, rotation cadence, revocation path,
and whether the host credential is mTLS, a bearer token over the tunnel, or
WireGuard peer identity itself. Do not design it inside the Provisioner slice;
inherit it.

---

## 3. Failure modes — the learning edge

This is where a remote host changes everything, and it is the reason issue #39
names the remote-Provisioner slice as its trigger. Athanor's existing recovery
philosophy is the right tool — *truth lives in Postgres rows; processes react to
truth, never own it; signals are disposable; sweep for correctness*
(`docs/supervision-tree.md`). The discipline below is that philosophy pushed
across a network boundary. Each failure is answered with the same four
questions: **who detects, who sweeps, what state lives where.**

### 3a. Unreachable runner host (boot time)

The control plane tries to boot a Runner; the host is down, the tunnel is
flapping, or the daemon is wedged.

- **Already solved by the existing design.** Boot is a supervised Task that
  writes `boot_deadline_at` at dispatch. A network-unreachable host is
  *indistinguishable* from a hung local Docker call — it is the same code path
  the supervision-tree doc already describes: deadline expires → sweep notices →
  re-queue (up to max boot attempts) → then `Failed` with reason `boot_failure`.
- **What state lives where:** the Job row and its `boot_deadline_at` column —
  control-plane Postgres. The host owns nothing yet.
- **One honest addition:** distinguish "host unreachable" from "host reachable,
  boot failed" *only* for instrumentation. Both map to `boot_failure`; the
  Failure Reason vocabulary doesn't need a new token. Keep the diagnostics in
  logs, not in a new state.

### 3b. Network partition mid-Job

The Runner is `Running`; the link between control plane and host drops.

- **Who detects:** the Runner's persistent WebSocket to the control plane drops
  (ADR 0001). From the control plane's side this is the **Channel process
  down-handler**, which stamps the **grace deadline** (`docs/supervision-tree.md`).
- **Who sweeps:** the periodic sweep. If the Runner rejoins with its Session
  Token within grace → resume. Else → `Failed` with reason `runner_lost`.
- **Subtlety the remote host introduces:** the Runner's *control-plane WS* and
  the *control-plane→host provisioner channel* are two different links that can
  fail independently. A partition can drop the Runner's WS while the firecracker
  VM keeps running on a perfectly healthy host. The control plane will correctly
  declare `runner_lost` — but the **VM is now an orphan burning host compute**
  (→ 3d). State truth is *unaffected* (the Job is correctly terminal); only
  compute leaks. This is exactly the scenario #39 was filed for.
- **What state lives where:** Job state + grace deadline in control-plane
  Postgres; the *physical VM/TAP/chroot* on the host, with no authoritative
  record on the host itself. The host is intentionally dumb — Postgres is the
  registry of what *should* exist.

### 3c. Control-plane restart while remote Jobs run

- **Already the headline of the supervision-tree doc:** a full BEAM restart is
  "every per-process failure at once," recovered identically because no process
  owned anything. Rows + deadlines + sweep survive; Runners auto-reconnect with
  Session Tokens.
- **Remote-host wrinkle:** the host-side provisioner daemon **must not** hold
  authoritative state that the control plane relies on to recover, or the
  restart story breaks. The daemon should be **stateless w.r.t. job truth** — it
  knows how to boot/destroy/enumerate, but "which VMs *should* exist" is read
  back from control-plane Postgres after restart. This is the single most
  important design constraint the remote split imposes, and it is just ADR 0002
  ("processes coordinate but never own state") extended to a process on another
  machine. If the host daemon kept its own job ledger, you'd have two sources of
  truth that can diverge across a partition — the exact failure CI systems are
  built to avoid.

### 3d. Orphaned VMs on a remote host nobody can reach

The terminal case: a VM (or TAP device, jailer chroot, cgroup) outlives its Job
because force-destroy crossed a network and failed, or the host was unreachable
at destroy time, or 3b happened.

- **The firecracker synthesis already specified the local version:** destroy is
  fire-and-forget idempotent (re-driven on duplicate `job:finished`), plus an
  **orphan sweep at startup** that enumerates host resources (`tap*`, jailer
  chroot dirs) and reconciles against live Runners in Postgres.
- **What the remote host changes:** the startup-only sweep becomes
  **insufficient**. Across a network, destroy failures are *routine*, not a
  startup anomaly — so the sweep must run **periodically**, and it must be keyed
  on **terminal Runner records** (issue #39's exact acceptance criterion:
  "containers belonging to terminal Runner records are eventually destroyed
  despite transient destroy failures"). This is the slice #39 said inherits the
  work.
- **Who detects / who sweeps:** the control plane is the only authority that
  knows "Runner X is terminal but its host resources may still exist." It drives
  a periodic reconcile — *for each terminal Runner, re-issue idempotent
  destroy* — and the **host-local daemon** is the executor that can actually
  enumerate and kill, because only it can see `tap*`/chroot/process state. This
  is the cleanest argument for option 4b over SSH (§4): the enumerate-and-kill
  logic wants to be a real program on the host, not a pile of remote shell.
- **"Nobody can reach the host":** if the host is *unreachable*, nothing can
  sweep it and that is acceptable — the leak is bounded compute on a box you
  own, and the reconcile *will* catch it the moment the host returns, because
  the terminal Runner records persist in Postgres. **No state truth is ever at
  risk; only host compute.** That bounded blast radius is exactly why #39 is
  parked-not-urgent until the remote slice exists.
- **No reconcile against non-terminal Runners** (#39's second criterion): a
  `Running` Runner's VM is *supposed* to exist; the reconcile must only ever act
  on terminal records, or it would race the happy path and kill live Jobs.

**Summary of "what state lives where" across all four:** Job/Runner state +
every deadline + the registry of what-should-exist live in **control-plane
Postgres**. The host owns **only physical resources** (VMs, TAP, chroots,
cgroups) and **no authoritative ledger**. Every failure mode resolves by the
control plane reading its own truth and re-driving an idempotent action against
a deliberately dumb host.

---

## 4. Where the Provisioner splits across hosts

The firecracker synthesis lists five Provisioner responsibilities: **image
store, boot, destroy, orphan sweep, cold-start instrumentation.** The question
is which land host-side under each split. All five touch host hardware *except*
cold-start instrumentation, which is fundamentally a control-plane measurement
(it times boot→first-join, and first-join is a control-plane event).

### (a) Thin remote exec — control plane SSHes to the host

The control plane shells out (`ssh host firecracker-boot …`). No host-side
program of Athanor's.

- **Host-side responsibilities:** boot, destroy, orphan sweep execute *on* the
  host but are *authored* as remote commands; image store lives on the host
  filesystem; cold-start instrumentation stays control-plane.
- **Pros:** least code; nothing new to deploy/version on the host; trivially
  inspectable (it's just commands).
- **Cons:** SSH session management, parsing stdout/exit codes as an API, no
  natural place for the **enumerate-and-reconcile** logic of #39 (it becomes
  brittle remote `ls /sys/class/net | grep tap` parsing), and the control-plane
  Task now blocks on an SSH round-trip per call. SSH key management is a *new*
  machine-auth surface that partially pre-empts the auth seam you wanted to
  defer. Boot is multi-step (TAP → chroot → jailer → API socket → InstanceStart,
  per firecracker §1–4); doing that over SSH one command at a time is fragile.
- **Verdict:** fine for a 30-minute spike to prove the wire; wrong as the
  destination, because #39's reconcile wants to be a real program.

### (b) Host-local provisioner daemon exposing an API the control plane calls — **recommended**

A small Go daemon on the runner host exposes `boot`/`destroy`/`enumerate` (and
streams cold-start timing back). The control-plane Provisioner Task makes a
call instead of a shell-out or a local Docker call.

- **Host-side responsibilities:** **image store, boot, destroy, orphan sweep** —
  all four physical responsibilities live in this daemon, which is exactly the
  firecracker synthesis's job description, just relocated to the host. The daemon
  is the natural home for the enumerate-`tap*`/chroot reconcile (#39).
  **Cold-start instrumentation** stays split: the daemon timestamps boot-start,
  the control plane timestamps first-join, the metric is computed
  control-plane-side.
- **Pros:** the daemon is a *proper program* — it can enumerate host state for
  reconciliation, make each cleanup step idempotent (the five-row destroy table
  from firecracker §7), and present a clean RPC surface. The control plane's
  model is **unchanged**: still a Task per boot/destroy, still fire-and-forget
  idempotent destroy, still deadline-driven recovery. The daemon is **stateless
  w.r.t. job truth** (§3c) — it executes and enumerates; it does not own.
- **Cons:** a second deployable artifact to build/version (mitigated: you
  already ship `athanor-runner` in Go; this is the same toolchain and the same
  team-of-one). Needs the host-auth credential (the deferred seam).
- **Verdict:** the sweet spot. It moves precisely the host-bound work to the
  host, keeps Postgres-as-truth and the singleton Scheduler exactly as designed,
  and gives #39 a real home. **This is the recommendation.**

### (c) Full agent that pulls from a queue and owns the host end-to-end

The vendor model (§1): a long-lived host agent long-polls the control plane for
work and runs the whole job lifecycle itself.

- **Host-side responsibilities:** *all five*, including cold-start
  instrumentation, because the agent now owns first-contact too. The agent
  effectively absorbs part of the Scheduler's dispatch role.
- **Pros:** outbound-only (best security/NAT story, §1); the industry-proven
  shape; scales to many hosts and hostile networks without rework.
- **Cons:** **it fights Athanor's current architecture.** The singleton
  Scheduler is "the only process that does `queued → assigned`"
  (`docs/supervision-tree.md`); a pulling agent claims work, which means the
  *agent* now participates in dispatch and you need atomic claims
  (`FOR UPDATE SKIP LOCKED`) — the multi-node change the supervision-tree doc
  explicitly scopes *out*. It risks the agent holding job state (violating §3c /
  ADR 0002) unless carefully designed. It's the most code and the most new
  coordination concepts at once. **For a learning project whose stated edge is
  coordination, this is the right thing to *graduate to*, not to start with** —
  doing it first means debugging distributed claims before you've debugged a
  single remote boot.
- **Verdict:** the correct long-term shape *if* fleets or untrusted networks
  arrive. Premature now; see §6.

**Mapping table — which responsibilities land host-side:**

| Responsibility | (a) SSH | (b) host daemon ✅ | (c) pull agent |
|---|---|---|---|
| Image store | host fs | host daemon | host agent |
| Boot | host (remote cmd) | host daemon | host agent |
| Destroy | host (remote cmd) | host daemon | host agent |
| Orphan sweep | host (brittle remote `ls`) | **host daemon (real program)** | host agent |
| Cold-start instrumentation | control plane | **split** (host stamps start, CP stamps first-join) | host agent (owns both) |
| Who initiates the wire | control plane → host | control plane → host | host → control plane |

---

## 5. BEAM-native vs language-agnostic transport

Two real options for the control-plane ↔ host-daemon link.

### Option A — Distributed Erlang to a host-side Elixir provisioner node

Run an Elixir node on the runner host, `Node.connect/1` it into the control
plane, call it like any other process (`:rpc`, `GenServer.call` to a global
name, etc.), optionally over Tailscale/WireGuard so EPMD + the distribution
port never touch the public internet.

- **Pros:** *delightful* for an Elixir-first developer. No serialization layer,
  no HTTP framing — you call a function on another machine. Process monitoring
  across nodes (`Process.monitor` a remote pid) gives partition detection nearly
  for free, which maps beautifully onto §3b. Mnesia/`:pg`/`:global` are all
  available. This is the BEAM at its most seductive.
- **Cons — and they are decisive for *this* box:**
  - **The trust model is inverted from what a runner host needs.**
    Distributed Erlang is a *high-trust* cluster protocol: a shared **cookie**
    is the only authentication, it "is not a robust authentication mechanism —
    just a sanity check," inter-node traffic is **cleartext by default**, and a
    node that joins the cluster can **run arbitrary code on every other node**
    *(verified — erlang.org, erlef.org, insinuator.net)*. The runner host is the
    machine *most likely to be compromised* (it runs customer code). Clustering
    your hardened control plane with your most-exposed box means a runner-host
    compromise is a **control-plane RCE**. That is the worst possible coupling.
  - **EPMD exposure is a known footgun** — ~85k publicly exposed EPMD instances
    in the wild *(verified — erlef.org)*. Even tunneled over WireGuard you must
    be rigorous that distribution never binds a public interface.
  - **TLS distribution** mitigates the cleartext/cookie problem but is fiddly to
    configure and still leaves the "any node can call any node" execution model.
  - **Operability:** dist-Erlang assumes a relatively stable mesh; a flapping
    runner host churns the cluster, and you inherit netsplit semantics you'd
    rather not debug as the *first* coordination lesson.

### Option B — Go host daemon over HTTP/WebSocket — **recommended**

The host daemon is a Go program; the control plane calls it over HTTP (for
request/response boot/destroy/enumerate) and/or a WebSocket (for streaming
cold-start timing and log relay if desired).

- **Pros:**
  - **You already proved this pattern.** ADR 0001 chose a persistent WebSocket
    using the **Phoenix-Channels protocol** for the Runner link. The host daemon
    can reuse the *exact same* muscle — Phoenix can be the server, the Go daemon
    a Channels client (the same shape `athanor-runner` already implements), or a
    plain authenticated HTTP endpoint for the simpler call/response surface.
  - **Bounded trust.** The daemon exposes a *narrow API* — boot, destroy,
    enumerate — not "run any function." A compromised runner host can call those
    three things, not pop a shell on the control plane. The blast radius matches
    §1's principle.
  - **Language-agnostic seam.** The host end is Go, which is where firecracker
    integration wants to be anyway (firecracker-go-sdk, jailer exec, TAP/nft
    syscalls — all the firecracker §1–4 work is Go-shaped). The control plane
    stays pure Elixir.
  - **Auth is a normal HTTP/WS auth problem** (bearer/mTLS over the WireGuard
    tunnel) — which hands the deferred machine-auth session a clean, conventional
    surface instead of a cookie.
- **Cons:**
  - You write serialization and an RPC surface by hand (small: three verbs).
  - You lose free cross-node process monitoring — but you *don't need it*,
    because partition detection already lives in the Runner's WS down-handler +
    deadline sweep (§3b). The control plane → host link failing is handled by the
    same deadline machinery as a hung boot (§3a). You are not giving up a
    capability you'd otherwise use.

**Honest trade-off for an Elixir-first developer:** dist-Erlang is more *fun* and
teaches you the BEAM's distribution primitives — genuinely valuable learning. But
the runner host is the **one machine in the system where the BEAM's high-trust
distribution model is actively dangerous**, and the project already has a
WebSocket protocol that demonstrates the safe pattern. Reach for dist-Erlang on
a *control-plane-to-control-plane* link someday (multi-node scheduler HA, the
`FOR UPDATE SKIP LOCKED` future the supervision-tree doc mentions) — that's a
mutually-trusting, stable mesh where it shines. Not on the link to the box
running customer code.

---

## 6. Recommendation for Athanor's concrete topology

**Topology:** control plane on the current box; **one bare-metal Ubuntu mini PC**
as the runner host (the homelab box, kernel 6.17 + `/dev/kvm` already verified in
firecracker §7); private network, WireGuard or Tailscale between them; hobby
scale; *possibly* a second host someday.

### Build first

1. **A Go host-local provisioner daemon (option 4b)** on the mini PC, exposing
   `boot` / `destroy` / `enumerate` over **HTTP/WebSocket** (option 5B), reusing
   the Phoenix-Channels muscle from ADR 0001 where streaming is wanted. It owns
   the four physical responsibilities (image store, boot, destroy, orphan sweep);
   cold-start instrumentation stays split (host stamps boot-start, control plane
   stamps first-join).
2. **Keep the control plane the initiator** (control-plane → host). At one
   trusted host on a private tunnel, the push model is acceptable and *much*
   simpler than inverting the singleton Scheduler into a claim-based pull (§4c).
   This is a deliberate, documented inversion of the industry default — correct
   for this scale, and the reasons it would be wrong at fleet scale (§1) are the
   reasons it's right here.
3. **The control-plane Provisioner Task is unchanged in shape** — still a Task
   per boot/destroy under the existing `Task.Supervisor`, still fire-and-forget
   idempotent destroy, still recovered by deadlines + sweep. The *only* change is
   the Task's body: "call the host daemon" instead of "call local dockerd." This
   is the smallest possible delta to the supervision tree — by design.
4. **Ship issue #39 with this slice.** Promote the firecracker startup-only
   orphan sweep to a **periodic reconcile** keyed on **terminal Runner records**,
   executed by the host daemon (which can enumerate `tap*`/chroot/cgroup) and
   driven by the control plane (which knows which Runners are terminal). Honor
   both #39 criteria: act only on terminal Runners, never on `Running` ones.
5. **The host-auth credential is a placeholder until the machine-auth session
   lands.** A bearer token over the WireGuard tunnel is a fine *temporary* seam;
   do not over-build it — inherit the real design.

### Defer

- **A second host** — but the option-4b daemon already makes this a "deploy the
  daemon on box 2 and register it" change, not a redesign. The control plane
  picks a host per boot; that selection logic is trivial for two hosts.
- **Host-initiated / outbound-only dispatch (option 4c, the pull agent).** This
  is the *graduation target* when (a) a host lives somewhere you can't dial into,
  or (b) you want to learn claim-based distributed dispatch
  (`FOR UPDATE SKIP LOCKED`) as a deliberate coordination lesson. Inverting
  push→pull later is contained: the daemon learns to long-poll, the Scheduler
  learns atomic claims. Don't pay for it before a second host or a hostile
  network makes it real.
- **mTLS / dist-Erlang TLS / cookie hardening** — moot under option 5B; the WG
  tunnel + a bearer token is sufficient for one trusted host. Revisit with the
  machine-auth session.
- **Warm pools / snapshots** — already deferred in firecracker §7; cold-start
  instrumentation (built in step 1) is what decides if they're ever worth it.

### The one-sentence version

Build a small stateless Go daemon on the mini PC that the Elixir control plane
calls over HTTP/WS to boot, destroy, and enumerate Firecracker Runners; keep
Postgres the source of truth and the Scheduler the singleton dispatcher
unchanged; and ship orphan reconciliation (#39) in the same slice because crossing
the network makes destroy-failure routine.

---

## Sources

- GitHub Actions self-hosted runners — outbound-only long poll (~50 s),
  60 s re-queue, "GitHub does not connect to your VM":
  [About self-hosted runners (GitHub Docs)](https://docs.github.com/en/actions/reference/runners/self-hosted-runners),
  [community discussion #26630 (ports)](https://github.com/orgs/community/discussions/26630)
- GitLab Runner — `glrt-` authentication tokens, registration, Workhorse +
  Redis PubSub long polling on `/api/v4/jobs/request`:
  [Registering runners](https://docs.gitlab.com/runner/register/),
  [Long polling](https://docs.gitlab.com/ci/runners/long_polling/),
  [Configuring runners](https://docs.gitlab.com/ci/runners/configure_runners/)
- Buildkite agent — agent token → session token → per-job job token; polling;
  `--acquire-job`:
  [Agent tokens](https://buildkite.com/docs/agent/self-hosted/tokens),
  [The Buildkite agent](https://buildkite.com/docs/agent),
  [buildkite-agent start](https://buildkite.com/docs/agent/v3/cli-start)
- Woodpecker CI — agent pulls from server queue over gRPC (port 9000), shared
  secret, server-minted agent ID persisted to file:
  [Architecture](https://woodpecker-ci.org/docs/development/architecture),
  [Agent config](https://woodpecker-ci.org/docs/administration/configuration/agent),
  [Agent deployment (DeepWiki)](https://deepwiki.com/woodpecker-ci/woodpecker/8.3-agent-deployment)
- Distributed Erlang security — cookie is "not robust authentication," cleartext
  by default, joining node can run arbitrary code, ~85k exposed EPMD instances,
  use TLS / never expose to untrusted networks:
  [Distributed Erlang (erlang.org)](https://www.erlang.org/doc/system/distributed.html),
  [Exposed EPMD (Erlang Ecosystem Foundation)](https://erlef.org/blog/eef/epmd-public-exposure),
  [Erlang distribution RCE & cookie bruteforcer (insinuator.net)](https://insinuator.net/2017/10/erlang-distribution-rce-and-a-cookie-bruteforcer/)
- Internal: `docs/adr/0001` (Phoenix-Channels WS Runner protocol),
  `docs/adr/0002` (Postgres source of truth), `docs/adr/0003` (ephemeral
  Runners), `docs/supervision-tree.md`, `docs/research/firecracker-runners.md`
  §7 + synthesis, `CONTEXT.md`, issue #39.

## Unverified — claimed from training knowledge, not re-checked this session

- **The deeper *why* of outbound-only convergence** (firewall/NAT asymmetry,
  blast-radius, backpressure, long-poll-erases-pull-cost) is synthesized
  reasoning, not a single citable source — the *mechanisms* per vendor are
  verified above; the *rationale framing* is mine. *(unverified as a unified claim)*
- **Exact current registration-token vs authentication-token migration state**
  per GitLab/GitHub version — the `glrt-`/registration-token shapes are verified,
  but precise deprecation timelines are version-specific and not pinned here.
  *(unverified)*
- **Drone vs Woodpecker divergence details** — treated together as the
  gRPC-pull lineage (Woodpecker is the Drone fork); Drone's *current* proprietary
  internals not re-checked. *(unverified for Drone specifically)*
- **Buildkite's exact poll-vs-long-poll wire behavior** — "polls for work" is
  verified; whether it uses long-poll holding like GitLab/GitHub is not
  explicitly confirmed. *(unverified)*
- **Firecracker / WireGuard / Tailscale specifics** carried from
  `firecracker-runners.md` and general knowledge, not re-verified this session.
  *(unverified)*
