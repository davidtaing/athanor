# GitHub App + webhook integration for a CI platform — research report

**Status:** research input, June 2026. Not an ADR, not a PRD.
**Feeds:** a future grill-why/PRD session on the "webhook Trigger" — the
post-MVP slice that adds a second **Trigger** source (push / PR) producing the
same **Pipeline** the API Trigger produces today.
**Frame:** the MVP cut-line (`CLAUDE.md`, `docs/prd/athanor-mvp.md`) is
API-triggered, public-repos-only, no secrets, no credential delivery to
Runners. Everything in this report is across that line. Per `CONTEXT.md`, a
webhook does not become a new concept — it becomes an **alternative Trigger**
that submits the same **Definition** schema and creates the same Pipeline. This
report is about what that one new Trigger source costs and how vendors do it.

Claims are tagged **stable** (cryptographic / protocol facts that rarely move)
or **volatile** (GitHub product specifics, limits, tunnel-service status).
Volatile claims are verified against cited sources; anything that couldn't be
verified is marked *(unverified)* inline and listed at the end.

---

## TL;DR recommendations

| Question | Recommendation |
|---|---|
| App type | **GitHub App**, not OAuth App or PAT. Per-installation scoping, fine-grained permissions, short-lived tokens, and its own webhook + identity are exactly the CI shape. |
| Auth flow | App holds a private key → signs a **JWT** (≤10 min) → exchanges it per-installation for a **1-hour installation access token**. The JWT authenticates "I am the App"; the installation token authenticates "I act on this installation's repos". |
| Webhook events | Subscribe to `push` and `pull_request` only for the first cut. Treat **fork PRs as untrusted** from day one (see fork-PR section). |
| Signature | Verify `X-Hub-Signature-256` (HMAC-SHA256 over **raw body bytes**, constant-time compare) before parsing. Reject on mismatch. **Non-negotiable.** |
| Idempotency | Dedupe on `X-GitHub-Delivery` (a GUID) with a unique constraint. Ack fast (return 2xx well under GitHub's ~10 s timeout), process async. |
| Reachability | **No public ingress — decided.** GitHub never reaches the homelab; tunnels (Cloudflare Tunnel, Tailscale Funnel) are ruled out. **Poll the GitHub API** as the primary Trigger source; an **owned cloud-side relay** drained outbound is the event-driven upgrade; **ngrok for attended demos only**. A future control plane on AWS dissolves the problem — and nested KVM on virtual EC2 (Feb 2026) keeps the Firecracker path open there. |
| Status reporting | Start with the **commit Statuses API** (one POST, trivial). Graduate to the **Checks API** when you want rich per-Job output, re-run buttons, and annotations. |
| Private-repo clone | Vendor practice: scope an installation token to the one repo, hand it to the build, `git clone https://x-access-token:<token>@github.com/...`. Token TTL (1 h) vs long Jobs is a real seam. **Auth/delivery design is owned by a separate machine-auth session — this report only names the seam.** |
| OSS reference | Woodpecker/Drone model: App/OAuth install adds a webhook per repo; inbound webhook → "create a build". Athanor's equivalent: webhook handler validates, maps payload → Definition, calls the **same** Pipeline-creation path the API Trigger uses. |

---

## 1. GitHub App vs OAuth App vs PAT / deploy keys

**Why GitHub App is the modern answer (stable, with volatile specifics).**

Three credential models, and they are not equivalent for a CI platform:

- **PAT / deploy keys** — A PAT is *a user's* token; it carries that user's
  full access and dies with the user (offboarding breaks CI). Deploy keys are
  per-repo SSH keys with no webhook identity and no org story. Both are fine for
  a one-off script, wrong for a platform that integrates with many repos.
- **OAuth App** — Acts *on behalf of a user* via an OAuth grant. Coarse scopes
  (`repo` is all-or-nothing across every repo the user can see), the token is
  long-lived, and there is no per-repo install boundary. Designed for "log in
  with GitHub", not for a service that needs scoped, auditable, per-repo write
  access to statuses and checks.
- **GitHub App** — A *first-class actor* with its own identity. The owner
  **installs** it on selected repos/orgs; each installation is independently
  scoped to a chosen permission set and repo list. The App authenticates as
  itself (not as a user), gets **short-lived** tokens, and has its **own**
  webhook configuration baked into the App definition rather than wired
  per-repo by hand. This is the model GitHub steers integrators toward and the
  one every serious CI integration (Actions checks, Woodpecker, Drone, etc.)
  uses.

For Athanor the deciding properties are: (a) **per-installation scoping** — the
blast radius of a leaked token is one installation's selected repos for one
hour, not a user's entire account forever; (b) **fine-grained permissions** —
request exactly `contents:read` (clone), `checks:write` or `statuses:write`
(report), `metadata:read`, `pull_requests:read`; (c) **the App is the audit
subject**, so status checks show up as "Athanor", not as David's user.

**The JWT → installation-token flow (stable shape, volatile numbers).**

1. The App has an RSA **private key**. It mints a **JWT** signed with that key,
   `iss` = the App ID, short `exp`. **Max JWT lifetime: 10 minutes.** This JWT
   authenticates *as the App* and can only call App-level endpoints (list
   installations, mint installation tokens).
2. To act on a repo, the App calls
   `POST /app/installations/{installation_id}/access_tokens` with the JWT and
   receives an **installation access token** valid for **1 hour**. You may
   request the token be **scoped down** to specific repositories and a subset
   of the App's permissions at mint time.
3. The installation token is what does real work (clone, post status). When it
   expires, mint a new one from a fresh JWT.

**Rate limits (volatile).** GitHub App installation tokens get a rate limit
that **scales with the number of repositories and org users** on the
installation, rather than the fixed per-user budget OAuth Apps get — i.e. a
busy CI App on a large org gets more headroom than a single PAT would. For a
hobby single-host platform on a handful of repos, the default budget is
effectively a non-issue.

**Token format change (volatile, near-future).** GitHub is rolling out a
**stateless installation-token format** (`ghs_<APPID>_<JWT>`-style) to newly
minted installation tokens, beginning a staged rollout in **2026**. Practical
takeaway: **never assume the token is exactly 40 characters** — treat it as an
opaque variable-length string. (Cited source states the rollout began April 27,
2026; exact reach/timing *(unverified)*.)

---

## 2. Webhook handling

**Which events matter for CI (stable).** For the first webhook Trigger, two
events carry essentially all the signal:

- **`push`** — branch/tag updates. The bread-and-butter Trigger: "run CI on
  what just landed". Payload gives the ref, before/after SHAs, and commits.
- **`pull_request`** — opened / synchronize (new commits pushed to the PR) /
  reopened. The "run CI on the proposed change" Trigger.

Everything else (`check_suite` rerequested, `release`, etc.) is a later
refinement. `ping` must be handled (GitHub sends it on webhook creation) by
just returning 200.

**The fork-PR trust problem (stable, important).** A PR from a **fork** carries
code the repo owner did not write. If your CI runs that code *with* access to
secrets/tokens, an attacker opens a PR whose build steps exfiltrate them. This
is the single most-exploited CI integration flaw — the GitHub Actions
`pull_request_target` family of incidents (several published advisory cases)
all reduce to "fork code ran with secret access". The lesson transfers directly
to Athanor:

- Builds for **fork PRs must run untrusted**: no installation token with write
  scope, no secrets, ideally no clone token beyond public read. Athanor's
  ephemeral-Runner-per-Job model already helps (the Runner *is* the sandbox and
  is destroyed after), but isolation does not stop exfiltration of any secret
  you *put inside* the sandbox.
- GitHub's own 2025 hardening (the `pull_request_target` event now always
  sources the workflow/ref from the **default branch**, effective late 2025)
  is a direct response to this class; the design principle to copy is
  **"untrusted code never sees privileged credentials"**, enforced by the Trigger
  layer, not by Runner isolation alone.
- For an MVP-of-the-webhook-Trigger, the cleanest cut is: **only build PRs from
  the same repo (not forks) when private/secret access is involved**; fork PRs
  get public-clone-only builds or are skipped. Defer "trusted maintainer
  approval to run fork CI" to later.

**Signature verification (stable).** GitHub signs each delivery with a shared
secret you configure on the App. Verify the **`X-Hub-Signature-256`** header
(HMAC-SHA256; the older `X-Hub-Signature` SHA-1 header exists for legacy and
should be ignored). Rules that matter:

- Compute HMAC-SHA256 over the **raw request body bytes** — not a re-serialized
  parse. In Phoenix this means capturing the raw body in a Plug **before** the
  JSON parser consumes it (a custom body reader that stashes `raw_body` in
  conn, then compares in a plug). Getting this wrong is the #1 webhook bug.
- Use a **constant-time comparison** (`Plug.Crypto.secure_compare/2`) to avoid
  timing attacks.
- Reject (401) on missing/mismatched signature before doing any work.

**Delivery semantics & idempotency (stable shape, volatile numbers).**

- GitHub expects a **fast response** and times out around **10 seconds**
  *(volatile, commonly cited)*. It **retries** on timeout or a 5xx, so you will
  receive the same event **more than once** — delivery is **at-least-once**.
- Every delivery carries a unique **`X-GitHub-Delivery`** GUID and an
  **`X-GitHub-Event`** header. **Dedupe on the GUID**: persist it with a unique
  constraint (a `webhook_deliveries` table is the natural Ash resource); if
  you've seen it, return 200 and stop. This is your idempotency key.
- Pattern: **ack first, work later.** Validate signature → record delivery →
  return 202/200 immediately → enqueue the "create Pipeline from this Trigger"
  work (a `Task`/Oban job). Do not create the Pipeline synchronously inside the
  request; a slow scheduler must never blow the 10 s budget and cause a retry
  storm.

**Redelivery / replay (volatile).** GitHub keeps a **Recent Deliveries** log
(request, payload, response, timing) with a manual **Redeliver** button, and
exposes a **REST API** to list deliveries and get/redeliver an individual one.
This is genuinely useful if a relay-based path (§3) is ever adopted: if the
relay or control plane was down, you can replay the missed deliveries rather
than losing those Triggers. Under §3's polling-primary recommendation there
are no deliveries to replay — the poller's last-seen cursor plays this
recovery role instead.

---

## 3. Reachability (decided constraint: the homelab takes no public ingress)

The governing decision, made June 2026: **the homelab will not be exposed to
the internet in any form.** That rules out not just port-forwarding but also
the outbound-initiated tunnels that are the standard self-hoster answer —
Cloudflare Tunnel and Tailscale Funnel open no inbound ports, but they publish
a public hostname that routes into the lab, and that counts as exposure here.
Consequence: **GitHub can never deliver a webhook to a homelab-resident
control plane.** Every viable option below is outbound-only from the lab.
(Recorded explicitly so future sessions don't re-propose tunnels.)

**Polling — recommended primary while the control plane lives in the lab
(stable).** The control plane polls the GitHub API on a timer using the App's
installation token: list commits / open PRs per enabled repo, diff against a
persisted last-seen cursor, synthesize a Trigger into the same
Pipeline-creation path. Trade-offs: Trigger latency equals the poll interval,
and it burns API quota — though at hobby repo counts a 30–60 s interval sits
far inside the 5,000 req/h installation budget, and conditional requests
(ETag/`304`) don't count against it. The quiet win: polling makes §2's
webhook-handler surface (signature verification, delivery dedupe) entirely
unnecessary — the poller *is* the Trigger adapter, and its cursor *is* the
recovery mechanism after downtime. (ADR 0001 rejected polling for the Runner
protocol; this is a different boundary — GitHub is the server here, and
seconds of Trigger latency are tolerable where Job dispatch latency is not.)

**Owned cloud-side relay — the event-driven upgrade path.** A small component
you own outside the lab (a Cloudflare Worker + queue, or a $5 VPS) receives
webhooks at a public endpoint, verifies and persists them, and the control
plane drains it over an **outbound** long-poll/SSE connection. Webhook-grade
latency and the full §2 surface, lab stays dark. Cost: you now operate and
secure a public cloud component — real weight for a hobby deployment. Adopt
only if polling latency starts to grate.

**ngrok — acceptable for one-off demos (decided).** For a live demo, a
temporary ngrok tunnel to the webhook handler is fine — it's exposure, but
deliberate, attended, and torn down afterward. A demo lane, not an
architecture: nothing durable gets registered against an ephemeral ngrok URL.

**smee.io — dev convenience only, same caveat.** The smee client is
outbound-only (SSE from smee.io to localhost), so the lab isn't listening —
but deliveries transit an unauthenticated third-party relay. Useful for
developing a webhook handler against real payloads; skippable entirely if
polling stays primary (there's no handler to develop). *(2026 operational
status unverified.)*

**The endgame that dissolves the problem: control plane on AWS (volatile,
verified Feb 2026).** If the control plane eventually moves to AWS, it gets an
ordinary public HTTPS endpoint and webhooks Just Work — §2 applies verbatim
and this whole section reduces to a TLS listener. That move stopped requiring
expensive `.metal` instances for the Firecracker ambition: **AWS added nested
virtualization on virtual EC2 instances (February 2026)** — KVM as an L1
hypervisor on C8i/M8i/R8i instance families, all commercial regions, no
Graviton support. So a single Intel-family EC2 instance can host the control
plane *and* boot Firecracker Runners under nested KVM. Caveats worth carrying
into that future decision: nested-virt performance overhead is real (it's
aimed at emulators/CI-style workloads, which is exactly this use), the
instance families are current-gen Intel only, and per-hour cost vs the
already-owned mini PC is the actual trade — the homelab remains the free
default. *(Nested-KVM performance under Firecracker specifically: unverified —
no published benchmarks found; measure before committing.)*

**Recommendation:** while the control plane is homelab-resident, **poll** —
it honors the no-ingress decision with zero extra infrastructure and makes
the webhook handler unnecessary. Keep the **owned relay** documented as the
event-driven upgrade, **ngrok** for attended demos only, and revisit the
whole question only if/when the control plane moves to AWS, where webhooks
become trivial and §2 applies as written.

---

## 4. Reporting status back: Checks API vs commit Statuses

Two mechanisms put a green/red mark on a commit/PR. They are not the same
maturity level.

**Commit Statuses API (stable, simplest).**
`POST /repos/{owner}/{repo}/statuses/{sha}` with `state`
(`pending`/`success`/`failure`/`error`), a `context` string (e.g.
`athanor/pipeline`), `description`, and `target_url` (link to logs). That's the
whole model: a flat list of named statuses per commit, last-write-wins per
context. It maps cleanly onto a **Pipeline rollup**: post `pending` when the
Pipeline is created, `success`/`failure` at the terminal verdict, `target_url`
→ the (future) LiveView Pipeline page. **Minimal viable integration = this.**
Needs only `statuses:write`.

**Checks API (volatile, richer).**
A two-level model: a **check suite** (GitHub auto-creates one per commit for
your App) contains **check runs** you create and update through a lifecycle
(`queued` → `in_progress` → `completed` with a `conclusion`). Each run carries a
title, summary, detailed **markdown output**, and **annotations** (file+line
findings) shown inline in the PR's Files view. It also gives users a native
**"Re-run"** button that fires a `check_run`/`check_suite` `rerequested`
webhook back to you. This is the model that fits Athanor's domain best
long-term: **one check run per Job**, the suite as the Pipeline rollup,
lifecycle states that line up with the Job lifecycle. Needs `checks:write`, and
note check runs are created on the repo the App is installed on.

**When each is appropriate.** Statuses for "I just need pass/fail on the PR with
a link" — perfect for the first webhook-Trigger slice. Checks when you want the
per-Job breakdown, rich logs/annotations in the GitHub UI, and re-run
ergonomics — the natural second iteration once Pipelines have a UI to link to.
**Recommendation: ship Statuses first (one POST, no lifecycle to model), adopt
Checks when per-Job visibility and re-run are worth the extra surface.**

---

## 5. Cloning private repos from ephemeral Runners

> **Scope guard:** this section describes **vendor practice and names the
> seam**. It does **not** design Athanor's credential-delivery mechanism — that
> belongs to the separate machine-auth research session. Treat the Boot
> Token / Session Token references as *the existing pattern to relate to*, not a
> proposal.

**Vendor practice (stable + volatile specifics).** To let a build clone a
private repo, integrators:

1. Mint an **installation access token scoped to that one repository** with
   `contents:read` (the minimum to clone), via the JWT → installation-token
   flow (§1).
2. Hand that token to the build environment.
3. Clone over HTTPS with the token in the URL:
   `git clone https://x-access-token:<token>@github.com/owner/repo.git`. The
   username `x-access-token` is a **convention** signalling "this is an
   installation token"; GitHub ignores the username field and authenticates on
   the token in the password slot. (A client secret is **never** valid here —
   only an installation token.)

**The real seam: token TTL vs Job duration.** The installation token lives
**1 hour** (§1). A Job that clones in its first seconds is fine. But this raises
two design questions that are **explicitly out of scope for this report**:

- **How the token travels to a Runner.** Athanor already has a credential that
  rides to a Runner at boot — the **Boot Token** (one-time, burned at first
  use, proves "the Provisioner booted me") — and a **Session Token** issued at
  join. A repo-scoped clone token is a *different* credential with a *different*
  trust story (it's a GitHub secret, not an Athanor-internal proof), so it
  should not be conflated with either. **Where it's minted, how it reaches the
  Runner, and whether it's injected at boot vs fetched at join is the seam the
  machine-auth session owns.**
- **Long Jobs outliving the token.** A Job that runs >1 h and needs git access
  late (re-fetch, submodules) can hit an expired token. Vendor answers vary
  (mint fresh per-clone and clone early; for long-lived needs, re-mint).
  Naming it here only so the machine-auth design accounts for it.

**Connection to the MVP cut-line:** private repos and *any* credential delivery
to Runners are explicitly out of MVP scope. This whole section is therefore
post-MVP, and its auth half is doubly deferred (separate session). The point
for the webhook-Trigger work is only: **a webhook Trigger for a private repo
implies a repo-scoped clone token, and that token's lifecycle is a known seam,
not a solved problem.**

---

## 6. How OSS CI tools map webhooks to builds (Woodpecker / Drone)

**The Woodpecker/Drone model (volatile specifics, stable shape).** Woodpecker
(a maintained fork of Drone) abstracts Git hosts behind a **"forge"** interface
(GitHub, Gitea, GitLab, …). The flow:

1. **Enable a repo** in Woodpecker. This requires admin rights on the repo
   because Woodpecker **creates a webhook on it automatically** (it does not ask
   you to wire hooks by hand).
2. The forge sends webhooks (push, PR, tag) to the Woodpecker **server**, which
   must be **reachable from the forge** — exactly the reachability problem of §3,
   and the reason self-hosters typically reach for tunnels (ruled out for
   Athanor; §3 polls instead).
3. On an inbound webhook, the server validates it, reads the in-repo pipeline
   file, and **creates a build/pipeline**, then schedules its work.

The load-bearing observation: in these tools the webhook is **just one Trigger
source feeding the same build-creation path** the rest of the system already
has. The forge integration is a thin adapter; the pipeline model underneath
doesn't change per Trigger.

**What Athanor's webhook-as-Trigger looks like at the API boundary (stable —
this is the design intent in `CONTEXT.md`).** This is the whole reason to
follow the glossary: a webhook **does not introduce a new domain concept**. It
is a **new Trigger source** that produces the **same Pipeline** from the **same
Definition schema** as today's API Trigger. Concretely:

- The webhook handler is an adapter: validate signature (§2) → dedupe on
  delivery GUID (§2) → map the `push`/`pull_request` payload (repo, ref, SHA,
  fork-or-not) into the **same Pipeline-creation call** the API Trigger uses.
- The internal seam stays at "create a Pipeline from a Definition". The API
  Trigger and the webhook Trigger are two front doors into one creation path —
  the API contract and the Pipeline/Job/Definition model are untouched.
- New responsibilities the webhook source adds (and the API source doesn't):
  fork-PR trust classification (§2), reachability (§3), and a place to **post
  status back** (§4) — none of which change what a Pipeline *is*.

**The parked YAML dependency (note, do not design).** Today the Definition is a
**JSON API body**; `CONTEXT.md` already says the same schema is "in-repo YAML
later". A webhook from a `push` is the natural moment you'd want to read a
Definition **out of the repo** (in-repo YAML) rather than receive it in the
request — that's how Woodpecker/Drone work. **In-repo YAML Definitions are a
separately-parked topic.** This report only flags the dependency: a fully
self-service webhook Trigger eventually wants in-repo YAML, but the webhook
Trigger can ship first against an externally-supplied Definition (e.g. a
Definition registered for the repo in the control plane), keeping the two slices
independent. **Do not design the YAML here.**

---

## Sources

- [Generating a JWT for a GitHub App — GitHub Docs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app) (JWT ≤10 min)
- [Generating an installation access token — GitHub Docs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app) (1-hour token, scope-down at mint)
- [Authenticating as a GitHub App installation — GitHub Docs](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation) (rate limit scales with repos/users)
- [Token expiration and revocation — GitHub Docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation) (stateless `ghs_APPID_JWT` token format rollout, 2026)
- [actions/create-github-app-token](https://github.com/actions/create-github-app-token) (reference impl of the JWT→token flow)
- [Validating webhook deliveries — GitHub Docs](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) (X-Hub-Signature-256, raw bytes, constant-time)
- [Webhook events and payloads — GitHub Docs](https://docs.github.com/en/webhooks/webhook-events-and-payloads) (push, pull_request)
- [Troubleshooting webhooks — GitHub Docs](https://docs.github.com/en/webhooks/testing-and-troubleshooting-webhooks/troubleshooting-webhooks) (~10 s timeout, retries, redelivery)
- [Hookdeck — GitHub webhooks features & best practices](https://hookdeck.com/webhooks/platforms/guide-github-webhooks-features-and-best-practices) (X-GitHub-Delivery GUID idempotency, redelivery API)
- [Actions pull_request_target / branch-protection changes — GitHub Changelog (2025-11-07)](https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/) (fork-PR hardening, default-branch sourcing)
- [openlit advisory GHSA-9jgv-x8cq-296q](https://github.com/openlit/openlit/security/advisories/GHSA-9jgv-x8cq-296q) and [spotipy GHSA-h25v-8c87-rvm8](https://github.com/spotipy-dev/spotipy/security/advisories/GHSA-h25v-8c87-rvm8) (fork-PR secret-exfiltration class)
- [Cloudflare Tunnel — official docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) and [Tailscale Funnel — official docs](https://tailscale.com/kb/1223/funnel) (primary references for the ruled-out tunnel options: outbound-initiated, but both publish a public hostname routed into the network — the property that disqualifies them under the no-public-ingress decision)
- Supplementary context only (third-party; ruled-out options, no load-bearing claims): [Cloudflare Tunnel in 2026](https://recca0120.github.io/en/2026/04/14/cloudflare-tunnel-2026/), [Tailscale vs Cloudflare Tunnel comparison](https://tech.breakingcube.com/2026/05/02/tailscale-vs-cloudflare-tunnel-zero-trust-comparison/), [Pinggy — Cloudflare Tunnel alternatives 2026](https://pinggy.io/blog/best_cloudflare_tunnel_alternatives/)
- [Woodpecker CI — your first pipeline](https://woodpecker-ci.org/docs/usage/intro) and [Self-host Woodpecker for Gitea/Forgejo 2026](https://ossalt.com/guides/self-host-woodpecker-ci-2026) (forge webhook auto-creation, server reachability, webhook→build)
- [Cloning private repo with a GitHub App — community discussion #24575](https://github.com/orgs/community/discussions/24575) and [git clone with installation token — discussion #173881](https://github.com/orgs/community/discussions/173881) (`x-access-token` convention, `contents:read`)
- [Amazon EC2 supports nested virtualization on virtual EC2 instances — AWS What's New (Feb 2026)](https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-ec2-nested-virtualization-on-virtual/) and [InfoQ coverage (Mar 2026)](https://www.infoq.com/news/2026/03/aws-ec2-nested-virtualization/) (KVM/Hyper-V as L1 on C8i/M8i/R8i, all commercial regions, no Graviton)

## Unverified claims

- **Stateless installation-token format rollout** (`ghs_APPID_JWT`): the cited
  source dates the staged rollout to April 27, 2026; the exact reach/timeline is
  *(unverified)*. Actionable regardless: treat installation tokens as opaque,
  variable-length strings.
- **Webhook delivery timeout = ~10 s**: widely and consistently cited, but the
  precise current value from primary GitHub docs was not pinned in this pass —
  *(unverified)* to the exact second; design for "respond fast, well under
  ~10 s".
- **smee.io 2026 operational status/limits**: not surfaced by search — *(unverified)*.
  Plan assumes it remains the standard GitHub-App dev relay; confirm it's live
  when the webhook-handler slice starts.
- **Firecracker performance under EC2 nested KVM**: the Feb 2026 nested-virt
  launch is verified, but no published Firecracker-under-nested-KVM benchmarks
  were found — *(unverified)*; measure before committing to an AWS endgame.
- **Tailscale Funnel "max 3 funnels per tailnet"**: commonly cited, not
  confirmed against current Tailscale docs in this pass — *(unverified)*.
- **GitHub App rate limit "scales with repos and org users"**: directionally
  confirmed (Apps differ from OAuth's fixed budget); the exact current formula
  was not pinned — *(unverified)*. Non-issue at hobby scale either way.
