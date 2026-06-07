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
| Auth flow | App holds a private key → signs a **JWT** (≤10 min) → exchanges it per-installation for a **1-hour installation access token**. The JWT authenticates "I am the App"; the installation token authenticates "I act on this install's repos". |
| Webhook events | Subscribe to `push` and `pull_request` only for the first cut. Treat **fork PRs as untrusted** from day one (see fork-PR section). |
| Signature | Verify `X-Hub-Signature-256` (HMAC-SHA256 over **raw body bytes**, constant-time compare) before parsing. Reject on mismatch. **Non-negotiable.** |
| Idempotency | Dedupe on `X-GitHub-Delivery` (a GUID) with a unique constraint. Ack fast (return 2xx well under GitHub's ~10 s timeout), process async. |
| Homelab reachability | **Cloudflare Tunnel** with a cheap owned domain is the lowest-friction durable answer. **smee.io** is the zero-cost dev relay. Tailscale Funnel and polling are fallbacks, not the primary. |
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
This is genuinely useful for a homelab: if your control plane was down, you can
replay the missed deliveries rather than losing those Triggers — a partial
mitigation for the reachability problem below.

---

## 3. Homelab reachability (the control plane runs on a home network)

This is the hard constraint that does not exist for cloud CI: **GitHub must
reach a service behind a home router with no public IP and no open inbound
ports.** Per the homelab topology, the control plane runs on a bare-metal mini
PC at home. Options, ranked for a hobby deployment:

**Cloudflare Tunnel — recommended primary (volatile).**
A `cloudflared` daemon on the mini PC makes an **outbound** connection to
Cloudflare; inbound webhooks arrive at a Cloudflare edge hostname and are piped
down the tunnel. **No open ports, no public IP.** With an **owned domain on
Cloudflare DNS** it runs free, indefinitely, for HTTP — you get a stable
hostname (`hooks.yourdomain.dev`), TLS, and DDoS/WAF in front of your home box.
Cost is just the domain (~$10/yr). The throwaway `trycloudflare.com` subdomain
exists for quick tests but is rate-limited and not for durable use. **This is
the best maturity/cost/control balance for Athanor:** stable URL to register in
the App, a security layer in front of a home network, and you own the name.

**smee.io — recommended for dev / first slice (volatile, *partially
unverified*).** GitHub's own webhook-relay service (the `smee-client` pattern
from the GitHub App dev docs): you point the App's webhook URL at a smee
channel, run a local client that forwards deliveries to `localhost`. Zero cost,
zero infra, no domain. Trade-off: it's a **public relay you don't control**, no
auth on the channel, and it's a dev convenience rather than a durable
production path. Ideal for building/testing the webhook handler before standing
up the tunnel. (Current smee.io operational status/limits *(unverified)* —
search did not surface 2026 specifics; treat as "still the standard dev relay,
confirm it's up when you reach this slice".)

**Tailscale Funnel — viable fallback (volatile).** Funnel exposes a tailnet
host on a public `*.ts.net` hostname. Zero-config, instant, free on the
personal plan — **but** it's still beta-ish, capped (commonly cited **max 3
funnels** per tailnet), gives no custom domain and no WAF. If you already run
Tailscale at home it's a fine no-extra-cost option; if not, it's more moving
parts than Cloudflare Tunnel for a public-facing endpoint. Tailscale's sweet
spot is *private* access, not public webhook ingestion.

**Polling fallback — the no-ingress escape hatch (stable).** If inbound is
truly off the table, the control plane can **poll** the GitHub API on a timer
(list commits / open PRs, diff against last-seen SHA, synthesize a Trigger).
Trade-offs: latency (poll interval), API quota burn, and more control-plane
logic. It's strictly worse than webhooks for a normal setup, but it's the
guaranteed-works floor and a reasonable degraded mode. Combined with the
redelivery API, it's also a backfill tool after downtime.

**Recommendation:** build the handler against **smee.io**, ship the durable
deployment on **Cloudflare Tunnel + owned domain**, keep **polling** in your
back pocket as a documented degraded mode. Lean on the **redelivery API** to
recover missed Triggers after the home box is offline.

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
   and the reason self-hosters reach for tunnels.
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
- [Cloudflare Tunnel in 2026 — expose localhost without open ports](https://recca0120.github.io/en/2026/04/14/cloudflare-tunnel-2026/) (free, owned domain, no inbound ports)
- [Tailscale vs Cloudflare Tunnel comparison](https://tech.breakingcube.com/2026/05/02/tailscale-vs-cloudflare-tunnel-zero-trust-comparison/) and [Pinggy — Cloudflare Tunnel alternatives 2026](https://pinggy.io/blog/best_cloudflare_tunnel_alternatives/) (Funnel beta, 3-funnel cap, public-vs-private fit)
- [Woodpecker CI — your first pipeline](https://woodpecker-ci.org/docs/usage/intro) and [Self-host Woodpecker for Gitea/Forgejo 2026](https://ossalt.com/guides/self-host-woodpecker-ci-2026) (forge webhook auto-creation, server reachability, webhook→build)
- [Cloning private repo with a GitHub App — community discussion #24575](https://github.com/orgs/community/discussions/24575) and [git clone with installation token — discussion #173881](https://github.com/orgs/community/discussions/173881) (`x-access-token` convention, `contents:read`)

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
- **Tailscale Funnel "max 3 funnels per tailnet"**: commonly cited, not
  confirmed against current Tailscale docs in this pass — *(unverified)*.
- **GitHub App rate limit "scales with repos and org users"**: directionally
  confirmed (Apps differ from OAuth's fixed budget); the exact current formula
  was not pinned — *(unverified)*. Non-issue at hobby scale either way.
