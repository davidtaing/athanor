# Research: secrets management for ephemeral, one-job Runners

**Status:** research report — input to a grilling session. A first grill happened
**2026-06-08**; its leanings are recorded in **§ Grill outcomes** at the end.
These are working decisions for when secrets get sliced, **not** ratified ADRs
and **not** an implementation — the MVP cut-line (no secrets) still stands.
**Date:** 2026-06-08 (research); grill appended 2026-06-08
**Issue:** #59.
**Frame:** the MVP has **no secrets** (cut-line, `CLAUDE.md`). This is a named
post-MVP exploration target. The report surveys how real CI systems deliver
secrets to throwaway Runners, lays out delivery/storage/exposure options against
Athanor's specific seams, and closes with open questions to grill — it does not
pick a winner.
**Builds on:** `docs/research/runner-auth-prior-art.md` (the Boot Token → Session
Token machine-auth seam — secrets delivery rides on top of that, it does not
re-derive it), ADR 0001 (Phoenix Channel over WebSocket), ADR 0002 (Postgres via
Ash is the source of truth), ADR 0003 (one ephemeral Runner per Job, the Runner
*is* the sandbox), ADR 0004 (logs to minio/S3, live tail via PubSub).

Claims are cited inline in **Sources**; anything not verified against a primary
source is marked *(unverified)*.

---

## TL;DR

- **The dominating fact is ADR 0003, not cryptography.** The Runner *is* the
  sandbox and it runs **arbitrary user Steps**. Any secret that is plaintext
  *inside* the container while a Step runs is exfiltratable — `env`,
  `/proc/*/environ`, files, process memory — and the egress is wide open
  (Synacktiv; the Megalodon/prt-scan campaigns are this exact attack at scale).
  This is the **same threat that makes the Boot Token single-use** (auth
  prior-art doc). So the secrets question is **not** "how do we hide secrets
  from the Runner" — we can't, by design — it is **"which secrets, scoped how
  tightly, for how short a window, reach a Runner the user's own code controls."**
- **Every real system converges on the same shape:** secret stored encrypted
  centrally → decrypted *late* (at job dispatch / job runtime) → handed to the
  job environment → masked best-effort in logs → gone when the ephemeral runner
  dies. They differ mainly in (a) whether the *platform* injects it or the job
  *pulls* it, and (b) whether the value is a long-lived static secret or a
  short-lived dynamically-minted credential. The maturity gradient is
  **static-secret-in-env → static-secret-as-file → dynamic/JIT short-lived
  credential** (Vault, GitHub OIDC) — exactly mirroring the auth doc's
  token-maturity gradient.
- **For Athanor's delivery channel, three candidates,** all of which assume the
  authenticated Channel from the auth doc already exists: (1) **push over the
  existing Channel** in (or alongside) `job:assign`; (2) **Runner pulls** via an
  authenticated API/Channel call using its Session Token; (3) **Provisioner
  injects** at boot as container env/files. Each trades differently against the
  auth seam, ephemerality, and the "anything in the container leaks" threat.
- **For storage at rest, the proportionate learning-project answer is almost
  certainly application-level envelope encryption in Postgres** (Cloak-style
  AES-GCM, a KEK from the environment) — *not* standing up Vault. Vault is what
  real systems reach for and is the right thing to *understand*, but at single
  host / one operator it is mostly operational tax. Worth a paragraph of "what
  it buys, when it'd be the trigger," not adoption.
- **The cheap, high-leverage wins are log masking and not-logging** (ADR 0004
  streams `log:chunk` and seals to minio — a leaked secret is **durable**), plus
  **file-over-env delivery** and **scrubbing the Runner environment** (the auth
  doc's finding #2 already wants `os.Unsetenv` after join — secrets generalize
  that one-liner into a policy).
- **Nothing here is MVP.** Flagged throughout as aspirational vs. near-term.

---

## 0. Why this is a real question even though the MVP has no secrets

The MVP cut-line is explicit: *no secrets, public repos only*. So why research
now? Because three already-decided things constrain what secrets can ever look
like, and getting them grilled before they're built is cheaper than retrofitting:

- **ADR 0003 (ephemeral, the Runner is the sandbox)** fixes the threat model: a
  secret's blast radius is bounded by one Job's lifetime *for free*, but the
  secret is fully exposed to that Job's arbitrary code. Ephemerality is the
  whole security story and also its hard limit.
- **The auth seam (Boot Token → Session Token)** is the *only* authenticated
  identity a Runner has. Secrets delivery has to ride on it. There is no second
  credential to invent.
- **ADR 0004 (logs are durable in minio)** turns the classic "secret in a log
  line" from an ephemeral embarrassment into a **persisted artifact**. Masking
  is therefore not optional polish; it is a property the log pipeline must have
  *before* secrets exist, because a sealed log object outlives the Runner that
  leaked into it.

The Definition already carries a per-Job **`env`** (flat string→string map,
validated at submission — `runner-protocol.md`). That is the natural seam a
secret would attach to, and it is already on the `job:assign` wire. So "where
would a secret even go" is already answered structurally; the open questions are
trust, storage, and exposure.

---

## 1. Prior art — how real systems deliver secrets to ephemeral runners

A survey of the systems in Athanor's reference set. The pattern is strikingly
uniform; the differences are in the trust model (who can decrypt, when).

### GitHub Actions

- **At rest:** secrets are encrypted **client-side before they reach GitHub**
  using **libsodium sealed boxes** — the caller encrypts with the repo's public
  key; GitHub holds the private key. This keeps plaintext out of GitHub's
  general storage/logging infrastructure.
- **Decryption is late:** values are **decrypted only at runtime, on the
  workflow runner**, surfaced via the `secrets` context as env vars / inputs.
- **Masking:** referenced secrets are auto-redacted from logs — **best-effort,
  not a guarantee** (see §4; base64/concatenation defeats it).
- **Trust boundary, load-bearing:** *with the exception of `GITHUB_TOKEN`,
  secrets are **not** passed to a runner when the workflow is triggered from a
  **forked** repo.* This is the public-repo analogue of Athanor's
  public-repos-only MVP: untrusted contributors must not get the secret.
- **Modern direction:** OIDC — the job mints a short-lived identity token and
  exchanges it with a cloud provider for **ephemeral** credentials, so no
  long-lived secret is stored at all. (Same shape as Nomad workload identity in
  the auth doc — the top maturity tier.)

### GitLab CI

- **Variable types:** **`Variable`** (injected as an env var) and **`File`**
  (GitLab writes the value to a temp file and sets the variable to the
  *path*). File-type exists *specifically* so `env`/`printenv` dumps don't spill
  the value, and so tools that want a credentials file get one. This is the
  cleanest expression of the **env-vs-file exposure trade-off** (§4).
- **Masking:** masked variables render as `[MASKED]` in logs — and GitLab's own
  docs warn masking is **not a guaranteed defense** against a malicious user,
  recommending File-type + external secrets for anything sensitive.
- **Protected variables / environments:** a variable can be scoped so it is only
  exposed on protected branches/tags — a *who-can-decrypt-when* control.
- **Dynamic path:** native HashiCorp Vault integration — at job time GitLab
  authenticates to Vault (increasingly via JWT/OIDC, not a stored token) and
  injects **short-lived** secrets that expire with the job.
- **History lesson:** GitLab shipped a real **masked-variable bypass** in
  Runner 13.9.0-rc1 — evidence that masking is fragile implementation surface,
  not a primitive.

### CircleCI

- **Contexts:** named buckets of env vars, **encrypted at rest and in transit**,
  shared across projects.
- **Restricted contexts:** access gated by security group / project restriction
  / config policy — only workflows for the allowed project(s) can read the
  context. A *who-can-decrypt* control layered on the store.
- **Masking** of secret values in logs, plus auditing of access to the secret
  store by CircleCI staff.
- **Documented attack class:** "shaking secrets out of CircleCI builds" — the
  malicious-PR / insecure-config path that exposes contexts; again the threat is
  arbitrary code with context access, not the store's crypto.

### Buildkite

- **Two models:** bring-your-own vault (AWS Secrets Manager, HashiCorp Vault) —
  **agents fetch on demand using short-lived session roles, pipelines never see
  raw plaintext at rest** — or **Buildkite Secrets** managed storage.
- **Ephemerality as the security story:** hosted agents are short-lived; "any
  data used during job execution, such as secrets or credentials, is destroyed
  after job completion or failure." This is **Athanor's own argument** (ADR
  0003) stated by a commercial vendor.
- The agent-pulls-from-vault model is prior art for Athanor's **pull** option
  (§2).

### Woodpecker / Drone (closest architectural cousins)

- Self-hosted, container-per-step, the nearest neighbours to Athanor's shape.
- **Secrets injected as env vars** into steps; the same value can be restricted
  to a **plugin allowlist** so it is *not* available to arbitrary user
  commands — **only to plugins, which cannot run arbitrary shell** and therefore
  cannot trivially exfiltrate. This is a sharp idea: **shrink the set of code
  that can see a secret** rather than trusting masking.
- **Trusted-repo / clone-credential gating:** git/clone credentials are injected
  only into **trusted** clone plugins on an allowlist; without it, a malicious
  PR could swap in a custom clone plugin and steal the credential. Direct
  parallel to GitHub's fork rule and Athanor's public-repo cut-line.
- **Fork-PR approval by default** on public repos — the untrusted-contributor
  boundary again.

### The cross-system pattern

| System | At rest | Decrypt when | Delivered as | Masking | Dynamic option |
|---|---|---|---|---|---|
| GitHub | sealed-box, client-side | runtime, on runner | env / input | best-effort | OIDC → cloud |
| GitLab | encrypted store | job runtime | **env or File** | `[MASKED]`, fragile | Vault/JWT |
| CircleCI | encrypted contexts | job runtime | env | yes | — |
| Buildkite | managed or BYO vault | **agent pulls** | env (+ session roles) | — | short-lived roles |
| Woodpecker/Drone | encrypted store | step runtime | env (+ **plugin allowlist**) | — | — |

**Three reusable ideas fall out:** (1) **encrypt at rest, decrypt late**;
(2) **File over env** to dodge `env`-dump exfiltration; (3) **scope who/what can
see a secret** — by branch (protected), by repo (restricted context / fork
rule), or by code (plugin allowlist) — because masking is a leaky last line, not
a boundary. And the strategic direction every mature system is moving toward is
**don't store a long-lived secret at all** — mint a short-lived one per job.

---

## 2. Delivery mechanism options for Athanor

All three assume the auth seam already authenticated the Runner. The question is
*how the plaintext secret reaches the Runner process*. The shared constraint:
once plaintext is in the container, ADR 0003 says the user's Step can read it —
so the comparison is about **timing, the size of the trusted path, and which
component does the decrypting**, not about hiding the value from the Job.

### Option A — Push over the existing Channel (in/alongside `job:assign`)

The control plane decrypts the secret and includes it in the `job:assign`
payload (or a dedicated follow-up server push), over the already-authenticated,
TLS/`wss`-protected Channel.

- **Pros:** zero new auth surface — rides the exact channel the auth doc already
  hardened; the control plane is the *only* decryptor (plaintext exists in CP
  memory + Runner memory, nowhere else); delivery is atomic with dispatch;
  fits ADR 0002 (CP owns truth, hands a fact to the Runner). The Definition's
  `env` map is *already* on this wire — secrets are a natural extension.
- **Cons:** plaintext secret transits the Channel and lands in Runner memory
  before any Step runs (acceptable — it has to land *somewhere* the Step can
  reach, by design). If `job:assign` is ever logged/persisted for debugging, the
  secret rides along — so the secret must be a **distinct, non-logged field**,
  not folded into the loggable `env`. Couples secret lifetime to the single
  dispatch message (no re-fetch without rejoin).
- **Auth-seam fit:** strongest — no new credential, no new endpoint.
- **Verdict:** the lowest-moving-parts option and the most ADR-aligned. Mirrors
  GitHub's "delivered via the same channel as the JIT config" (auth doc).

### Option B — Runner pulls via an authenticated call (Session Token)

The Runner, after first join, makes an authenticated request — a Channel
message (`secrets:fetch`) or an HTTP call — presenting its **Session Token**, and
the control plane returns the decrypted secrets.

- **Pros:** decryption deferred to the latest possible moment (just-in-time, just
  before Steps need it); natural seam for **rotating/dynamic** secrets later
  (the pull can mint a short-lived credential on demand — Buildkite/Vault
  shape); keeps secrets out of the dispatch message entirely.
- **Cons:** introduces a **new authorization surface** — "which Runner may fetch
  which secret" — that must be bound to the Job, exactly as tightly as the
  Session Token is bound to the Runner. The auth doc is explicit that the
  Session Token must **never be Step-reachable** (memory only); a pull endpoint
  raises the stakes — if a Step can reach the Session Token *and* the endpoint,
  it can re-pull. An HTTP variant also means a *second* transport to secure
  (the Channel is already `wss`); a Channel-message variant avoids that.
- **Auth-seam fit:** good, but it **spends** the Session Token's confidentiality
  budget — worth grilling against finding #2 of the auth doc.
- **Verdict:** more flexible, more surface. Justified only once dynamic/JIT
  secrets are on the table; overkill for static secrets where Option A suffices.

### Option C — Provisioner injects at boot (container env / files)

The Provisioner decrypts and bakes secrets into the container as env vars or
mounted files at boot — the same path it already uses for the Boot Token and
control-plane URL (auth doc / firecracker doc: "injected as env vars").

- **Pros:** simplest mechanically — reuses the existing boot-config injection;
  no protocol message at all; the secret is present before the Runner even
  joins.
- **Cons (significant):** widens the trusted path to include the **Provisioner**
  and the **container-create call** — and once the Provisioner is *remote*
  (issue #39's trigger; `remote-runner-host.md`), that call **crosses the
  network** and the secret rides inside it, exactly like the Boot Token does.
  The auth doc tolerates that for the Boot Token *because it is single-use and
  90 s-lived*; a real secret has neither property, so the calculus is worse.
  Boot-time injection also means the secret is in `docker inspect` /
  `/proc/1/environ` for the **whole** Runner lifetime, not just when a Step needs
  it. Env injection specifically is the most exfiltration-prone form (§4).
- **Auth-seam fit:** weakest — it bypasses the Channel's identity entirely and
  leans on the Provisioner→host trust boundary, which is itself unresolved
  (`remote-runner-host.md` ranks Tailscale+SSH etc.).
- **Verdict:** tempting because it's free, but it puts the secret on the
  *boot* path (network-crossing, long-lived-in-container) rather than the
  *dispatch* path. For the firecracker future, MMDS V2 (firecracker doc) is the
  cleaner equivalent, but the trust analysis is the same.

### Cross-cutting: this is the auth doc's gradient again

The auth doc's maturity ladder — *shared long-lived → per-runner → single-use
bootstrap → no-shared-secret signed identity* — has a secrets twin:
*static-secret-in-env → static-as-file → short-lived/dynamic minted per job →
no stored secret (OIDC/Vault JWT)*. Athanor's **Option A with a static secret**
sits low on that ladder (fine for a learning project); **Option B with a
dynamically-minted credential** is the rung GitHub/GitLab/Buildkite have climbed
to. Naming where Athanor wants to sit is a grill question, not a research
conclusion.

---

## 3. Storage at rest

ADR 0002 makes Postgres (via Ash) the source of truth. The question is whether a
secret's *ciphertext* lives there (encrypted) or in an **external store** (Vault
et al.). What's proportionate for a single-host learning project differs sharply
from what real systems do.

### Option 1 — Application-level envelope encryption in Postgres (the proportionate answer)

- **Mechanism:** a per-secret random **DEK** (data encryption key) encrypts the
  value with **AES-GCM**; the DEK is itself wrapped by a **KEK** (key-encryption
  key) held outside the row (env var / file / later a KMS). Only ciphertext +
  wrapped-DEK + algorithm metadata land in Postgres. This is textbook envelope
  encryption (KEK wraps DEK, DEK encrypts data).
- **Elixir fit:** **Cloak / `cloak_ecto`** does exactly this transparently for
  Ecto fields — AES-GCM cipher, a configured key vault, ciphertext self-
  describing (algorithm + key tag embedded) so key rotation is a re-encrypt, not
  a schema change. Ash sits on Ecto, and the Boot/Session tokens are *already*
  `sensitive?: true` Ash attributes (`runner-protocol.md`) — so the codebase
  already has the "this attribute is sensitive" concept; encryption-at-rest is
  the next notch. *(Exact Ash↔Cloak ergonomics unverified — flag as a spike.)*
- **Key management — the honest hard part:** envelope encryption relocates the
  problem to "where does the KEK live and who can read it." On a single mini PC
  the KEK is realistically an env var or a file readable by the BEAM — which
  means **a control-plane compromise yields the KEK and thus every secret.** The
  TPM-bound options (`systemd-creds`, TPM-sealed LUKS) noted in the auth doc are
  the cheap real win if hardware-rooted KEK protection is ever wanted; out of
  scope now.
- **What it buys:** ciphertext-at-rest means a stolen DB backup / leaked dump
  isn't immediately plaintext secrets (the dominant real-world leak path), and
  it gives a rotation story. What it does **not** buy: protection from a live
  control-plane compromise (the process holds the KEK). That's an honest,
  proportionate boundary for a single-operator learning project.

### Option 2 — External secrets store (Vault / OpenBao)

- **What real systems do**, and the right thing to *understand*: Vault's value is
  **dynamic secrets** (mint short-lived, per-job, auto-expiring credentials —
  the JIT model that collapses the "stored long-lived secret" risk entirely),
  centralized audit, fine-grained policy, and the **Transit engine** doing
  KEK-as-a-service (encryption-as-a-service so the app never holds the KEK —
  the clean answer to Option 1's KEK problem).
- **Why it's disproportionate now** (mirrors the auth doc's SPIFFE verdict
  almost exactly): at single host / one operator, Vault is server lifecycle,
  unseal-key custody, policy authoring, and a second stateful system to run —
  operational tax that lands on one person, for a learning project with no
  secrets yet. Its differentiator (dynamic secrets, multi-consumer policy) has
  no consumer at this scale.
- **When it'd be the trigger:** real secrets that must be *rotated* or *scoped
  per-consumer*; multiple operators; or the explicit desire to learn dynamic-
  secret issuance as a topic in its own right. **OpenBao** (the open-source
  Vault fork) is the license-clean variant worth naming given the repo's
  IP-clearance caution (memory: skill-capital strategy).

### Recommendation-with-caveats

For the *first* time secrets exist: **Cloak-style envelope encryption in
Postgres**, KEK from the environment, value delivered via Option A. It is
proportionate, it keeps ADR 0002's "Postgres is truth" intact (the *ciphertext*
is the truth), and it teaches envelope encryption without standing up a second
system. Vault/OpenBao is the **named post-MVP exploration** for when dynamic
secrets become the actual learning goal — not adoption, a paragraph in the ADR.

---

## 4. Exposure surface — env vs files, log masking, lifetime

This is where the cheap, high-leverage work is, and where ADR 0004 makes it
**mandatory rather than optional**.

### Env vs files

- **Env vars are the most exfiltration-prone form.** `env` / `printenv`,
  `/proc/<pid>/environ`, `docker inspect`, and child-process inheritance all
  surface them. The Megalodon/prt-scan campaigns literally **poll
  `/proc/*/environ` every 2 s** for new high-value variables. The auth doc's
  finding #2 already caught this for the Boot Token: `executor/shell.go` runs
  Steps without setting `cmd.Env`, so children **inherit the Runner's
  environment**. For secrets that is a direct leak path.
- **File-type delivery (GitLab's model)** writes the value to a file and exposes
  only the *path* — dodging `env` dumps and matching tools that want a
  credentials file. It does not stop a deliberate `cat`, but it removes the
  *accidental* and *broad-sweep* exposure. A plausible Athanor stance: secrets
  go to a file under a tmpfs path, not into the `env` map.
- **Child-environment scrubbing:** the auth doc wants one line —
  `os.Unsetenv`/scrubbed `cmd.Env` after join — so Steps don't inherit the
  Runner's own credentials. Secrets **generalize that into a policy**: the Step
  subprocess environment should be **explicitly constructed**, containing only
  what the Definition asked for, never the Runner's auth tokens or unrelated
  secrets. Worth a one-line invariant in `runner-protocol.md` before any secret
  lands, exactly as the auth doc proposed for the Session Token.

### Log masking — and why ADR 0004 raises the stakes

- Athanor's log path (ADR 0004): Runner streams `log:chunk` → CP re-broadcasts on
  PubSub for live tail **and flushes chunks to minio**, then **seals** them into
  one durable object. So a secret that lands in a log line is **persisted**, not
  merely flashed on a console. Masking is therefore a property the **log
  pipeline** needs, ideally *before* secrets exist.
- **Masking is best-effort and provably leaky.** GitHub redacts but warns it
  can't catch everything; GitLab shipped a real masked-variable bypass; the
  canonical defeats are **base64 / double-base64**, **splitting the secret
  across lines**, and **appending a suffix** so the literal substring never
  appears. Synacktiv's writeup demonstrates
  `env | grep ^secret_ | base64 | base64` as a one-liner that sails past
  masking. **Conclusion: masking is a guard-rail against *accidental* echo, not
  a control against a *malicious* Step.** The auth doc's token-prefix idea
  (`athanor_sess_`) helps here too — prefixed secrets are machine-recognizable
  if they do leak.
- **Where to mask matters under ADR 0004.** Masking on the **Runner** (before
  the bytes ever enter `log:chunk`) protects both the live-tail PubSub path and
  the sealed minio object, and keeps the plaintext from ever crossing the wire
  in a log frame. Masking only on the **control plane** still lets plaintext
  transit the Channel and risks the PubSub broadcast racing the redaction.
  Runner-side masking-at-source looks like the right default — a grill question.

### Lifetime / zeroization on the ephemeral Runner

- Ephemerality does most of the work: the container (and its memory, env, tmpfs
  files) is **destroyed at terminal state** (ADR 0003) — the secret's at-rest
  lifetime on the Runner is one Job. This is the property Buildkite markets and
  the auth doc relies on.
- What ephemerality does **not** give: protection *during* the Job (the Step
  owns the box), nor guaranteed zeroization of a secret that was copied
  elsewhere (a build artifact, a cache — both out of MVP scope, but a future
  caching feature could persist a secret-bearing layer — cross-ref
  `caching-ephemeral-runners.md`). For Firecracker, "destroy" must also wipe the
  per-VM rootfs copy / CoW overlay (firecracker doc §7 cleanup) — the secret is
  in that ext4 image, so the cleanup table is also a secrets-zeroization table.

---

## 5. Threat model

What ephemerality and the auth seam buy for free, and what they don't.

| Threat | Bought for free? | Residual / what to grill |
|---|---|---|
| **Malicious Pipeline Definition** (attacker authors Steps that dump secrets) | **No** — this is the design's hard edge. The Step is arbitrary code with full access to whatever plaintext is in the container. | The *only* real defenses are **scope** (don't give this Job that secret — fork rule / protected-branch / plugin-allowlist analogues) and **least secret** (deliver only what the Definition declared). For public-repo MVP this maps to: **untrusted Definitions get no secrets at all**, the GitHub fork rule. |
| **Compromised Step** (legit pipeline, dependency/supply-chain takeover at runtime) | Partially — blast radius capped to one Job + its declared secrets by ephemerality. | Same as above plus **short-lived/dynamic secrets** (Option B + Vault) so a stolen value expires fast. Static secrets stay valid until manually rotated. |
| **Log exfiltration** (secret echoed/encoded into logs) | **No** — and ADR 0004 makes it **durable** in minio. | Mask-at-source on the Runner; treat masking as accident-prevention not control; consider redaction at seal time as a backstop. |
| **Leaked / replayed token** | Partially. The Boot Token is single-use + 90 s (auth doc); the Session Token dies with the Job. | If secrets ride the Session Token (Option B), a Step that can read it can re-pull secrets. Cross-ref **issue #71** (burned-token replay is a discarded tamper signal): the same tamper-evidence logic should extend to "a Session Token used from an unexpected context." Keep secrets off any Step-reachable credential. |
| **Stolen DB backup / dump** | No (plaintext today). | Envelope encryption (§3) directly addresses this — the dominant real leak path. |
| **Control-plane compromise** | No. | CP holds the KEK and decrypts everything; envelope encryption does not defend this. Vault Transit / TPM-sealed KEK would; both out of scope. Name it as the accepted boundary. |
| **Provisioner / boot-path interception** (Option C, remote host) | Partially (the channel can be encrypted). | A real secret lacks the Boot Token's single-use/90 s mitigations, so boot-path delivery is a worse bet than dispatch-path. Cross-ref `remote-runner-host.md`. |

**The one-sentence threat model:** *ephemerality bounds a secret's blast radius
to one Job and one Job's lifetime, and the auth seam ensures only a
Provisioner-booted Runner gets that far — but inside the Job, the user's code is
root over the secret, so the entire game is **which** secret reaches **which**
Job, scoped how tightly, and for how short a window.* That is the same lesson the
auth doc drew for tokens, applied to secrets.

---

## What this means for Athanor (synthesis + caveats)

- **None of this is MVP.** The cut-line stands: no secrets, public repos only.
  This report is the pre-grill for the eventual post-MVP slice.
- **The structural seam already exists.** The Definition's per-Job `env` map and
  the `job:assign` push are where a secret would attach; **Option A (push over
  the Channel)** is the most ADR-aligned, lowest-surface delivery and the natural
  first cut.
- **Storage: envelope-encrypt in Postgres (Cloak-style), KEK from env.**
  Proportionate, keeps ADR 0002 intact, teaches envelope encryption.
  Vault/OpenBao is a named exploration for when **dynamic secrets** become the
  learning goal — not adoption now.
- **The cheap wins are exposure-surface wins, and some want doing *before*
  secrets exist:** mask-at-source on the Runner (ADR 0004 makes leaks durable),
  prefer **file-over-env** delivery, and **scrub the Step subprocess
  environment** (generalizing the auth doc's `os.Unsetenv` one-liner into a
  policy + a `runner-protocol.md` invariant).
- **The first product decision isn't crypto, it's scope:** for public-repo /
  untrusted Definitions, the proven answer (GitHub fork rule, Woodpecker
  trusted-repo gating) is **untrusted Definitions get no secrets**. That's a
  product/PRD question — grill-why territory — more than an engineering one.

### Open questions to grill

1. **Where does a secret sit relative to the trust boundary of arbitrary user
   code?** Given ADR 0003 says the Step is root over anything in the container,
   is the *only* real control "which Job gets which secret" (scope), and does
   that make the first secrets decision a **product** decision (who's trusted)
   rather than a crypto one? What's the public-repo analogue of GitHub's fork
   rule for Athanor?
2. **Delivery: push (A) vs pull (B)?** Does the flexibility of a Runner-pull
   (JIT, dynamic-secret-ready) justify spending the Session Token's
   confidentiality budget and adding an authorization surface — when Option A
   over the existing Channel covers static secrets with zero new surface? Which
   maturity rung does Athanor *want* to sit on?
3. **How much masking is honest?** Given ADR 0004 persists logs and masking is
   provably defeatable (base64/split/suffix), is Runner-side mask-at-source the
   right default, and do we state plainly that masking guards against *accidents*
   and never against a *malicious* Step — so we don't oversell it?
4. *(Secondary)* **Is envelope-encryption-in-Postgres the right stopping point,
   or is standing up OpenBao to learn dynamic secrets the more valuable
   learning slice** — accepting it's disproportionate as *infrastructure*?

---

## Grill outcomes (2026-06-08 session)

A first grilling pass over the four open questions above. These are **leanings**
to carry into the eventual post-MVP secrets slice — working decisions, not
ratified ADRs. The cut-line (no secrets, public repos only) is unchanged; nothing
here is built. The framing that drove the whole session: *"protect secrets in the
Runner" is largely the wrong goal* — ADR 0003 makes the Step root over any
plaintext in the container, so every choice below is downstream of the real
control, which is **scope**.

1. **Trust boundary (Q1) — scope is the only real control, and the first
   decision is a product one.** Because masking and crypto don't hold against
   malicious Step code, the load-bearing rule is *which Job gets which secret*.
   Every mature system converged here (GitHub fork rule, Woodpecker trusted-repo
   gating). Athanor's public-repo analogue: **untrusted Definitions get no
   secrets, full stop** — a secret is bound to a Pipeline and reaches a Runner
   only for trusted (owner-authored) Definitions, never an arbitrary public-PR
   author. **This belongs in the PRD, not an ADR** — it's a trust/product call,
   not an engineering one.

2. **Delivery (Q2) — Option A (push over the existing Channel) for static
   secrets.** Zero new auth surface; the control plane is the only decryptor.
   Option B (Runner-pull on the Session Token) is deferred until there's a
   *consumer* for dynamic/JIT secrets — until then it only spends the Session
   Token's "never Step-reachable" budget for no gain. **Discipline that comes
   with Option A:** the secret must ride a **distinct, non-logged field**, never
   folded into the loggable `env` map on `job:assign`, and never persisted with
   the dispatch record.

3. **Masking (Q3) — mask at source on the Runner, and say plainly it's
   accident-prevention only.** ADR 0004 makes leaks *durable* in minio, so
   masking must happen **before bytes enter `log:chunk`** (CP-side masking lets
   plaintext cross the wire and race the PubSub broadcast). State the limit in
   the spec without overselling: base64 / split-across-lines / suffix defeat it
   trivially — it guards against accidental echo, never a malicious Step.

4. **Storage (Q4) — Cloak-style envelope encryption in Postgres, KEK from the
   environment. No Vault/OpenBao now.** Proportionate for single-host /
   single-operator; keeps ADR 0002 intact (the *ciphertext* is the truth) and
   teaches envelope encryption without a second stateful system. **Accepted
   boundary, named honestly:** this defends a stolen DB dump (the dominant real
   leak path) but **not** a live control-plane compromise (the BEAM holds the
   KEK). OpenBao stays the named exploration for when *dynamic secrets* are the
   actual learning goal — a paragraph in a future ADR, not adoption.

**Pulled forward — pre-secrets hardening (sliceable now, issue #82).** The
cheapest win wants doing *before* secrets exist and is a latent bug today:
**explicitly construct the Step subprocess environment** instead of inheriting
it. As built, `cmd.Env` is unset so Steps inherit the Runner's bootstrap vars
(`ATHANOR_BOOT_TOKEN` leaks), and the declared `env` map is received but never
applied. One change closes both, makes `env` work, and establishes the invariant
(now recorded in `runner-protocol.md`) that **file-over-env-on-tmpfs** secret
delivery later builds on — write the value to a tmpfs file, set the env var to
the *path*, get zeroization for free when the ephemeral Runner dies (ADR 0003).

**Still open / not grilled:** whether to ever climb to dynamic/JIT secrets (the
trigger for Option B + OpenBao); the exact `cmd.Env` base set Steps legitimately
need; redaction-at-seal-time as a masking backstop. Revisit when a secrets
consumer actually exists.

---

## Sources

Prior art:
[GitHub Actions — using secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions) ·
[GitHub Actions — secrets concepts (libsodium sealed boxes, runtime decryption)](https://docs.github.com/en/actions/concepts/security/secrets) ·
[GitHub libsodium secret-encryption discussion](https://github.com/orgs/community/discussions/26535) ·
[GitLab CI/CD variables (Variable vs File, protected, masking caveat)](https://docs.gitlab.com/ci/variables/) ·
[GitLab masked-variable vulnerability (Runner 13.9.0-rc1)](https://about.gitlab.com/blog/2021/02/18/masked-variable-vulnerability-in-runner-ver-13-9-0-rc1/) ·
[CircleCI contexts & restricted contexts](https://circleci.com/docs/contexts/) ·
[CircleCI — protect secrets with restricted contexts](https://circleci.com/blog/protect-secrets-with-restricted-contexts/) ·
[Shaking secrets out of CircleCI builds (Nathan Davison)](https://nathandavison.com/blog/shaking-secrets-out-of-circleci-builds) ·
[Buildkite hosted agents (ephemeral, secrets destroyed after job)](https://buildkite.com/docs/agent/buildkite-hosted) ·
[Buildkite security](https://buildkite.com/about/security/) ·
[Woodpecker CI — secrets (plugin allowlist, trusted clone)](https://woodpecker-ci.org/docs/usage/secrets)

Delivery / storage / dynamic:
[HashiCorp WAF — dynamic vs static secrets in CI/CD](https://developer.hashicorp.com/well-architected-framework/secure-systems/secure-applications/ci-cd-secrets/dynamic-and-static-secrets) ·
[HashiCorp WAF — secure GitLab CI/CD secrets with Vault (JWT/OIDC, short-lived)](https://developer.hashicorp.com/well-architected-framework/secure-systems/secure-applications/ci-cd-secrets/gitlab) ·
[HashiCorp — Transit engine as high-performance envelope encryption (KEK/DEK)](https://www.hashicorp.com/en/blog/adopting-hashicorp-vaults-transit-engine-high-performance-envelope-encryption-ariso-ai) ·
[Cloak — Elixir encryption for Ecto (AES-GCM, vault, self-describing ciphertext)](https://github.com/danielberkompas/cloak) ·
[cloak_ecto docs](https://hexdocs.pm/cloak_ecto/) ·
[Envelope encryption primer (KEK wraps DEK)](https://medium.com/@tarangchikhalia/envelope-encryption-a-secure-approach-to-secrets-management-c8abce5b24d2)

Threat model / masking bypass:
[Synacktiv — CI/CD secrets extraction, tips and tricks](https://www.synacktiv.com/en/publications/cicd-secrets-extraction-tips-and-tricks) ·
[StepSecurity — Megalodon mass GitHub Actions secret exfiltration](https://www.stepsecurity.io/blog/megalodon-mass-github-actions-secret-exfiltration-across-5-500-public-repositories) ·
[SafeDep — prt-scan GitHub Actions credential-theft campaign](https://safedep.io/prt-scan-github-actions-exfiltration-campaign/) ·
[actions/runner #291 — base64 masking does not account for appended strings](https://github.com/actions/runner/issues/291)

Athanor internal (not duplicated):
`docs/research/runner-auth-prior-art.md` (Boot/Session Token seam; findings #1 burned-replay, #2 env inheritance) ·
`docs/research/remote-runner-host.md` (Provisioner→host channel) ·
`docs/research/firecracker-runners.md` (MMDS V2, per-VM cleanup/zeroization) ·
`docs/research/caching-ephemeral-runners.md` (secret-bearing cache layers, future) ·
ADRs 0001–0004 · `docs/specs/runner-protocol.md` (`env` map, `sensitive?` tokens) ·
`CONTEXT.md` (Pipeline, Job, Runner, Provisioner, Definition, Boot/Session Token) ·
issue #71 (burned-token replay tamper signal — extends to secret-fetch context).

**Unverified, by deliberate choice not to over-fetch:** exact Ash↔Cloak
integration ergonomics (flagged as a spike); CircleCI/Buildkite internal at-rest
crypto beyond "encrypted at rest"; whether GitHub's runtime decryption holds the
private key on the runner vs. CP-side (docs say "decrypted at runtime on the
runner" — exact key location not first-party-confirmed).
