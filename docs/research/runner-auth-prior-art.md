# Research: runner auth vs prior art, and trust for a remote runner host

**Status:** research report — input to a future grilling session, not a decision.
**Date:** 2026-06-08
**Scope:** two layers. Layer 1 gap-checks the built Boot Token → Session Token
design against prior art (evaluate, don't redesign). Layer 2 surveys options for
trusting the remote runner host once the Provisioner crosses the network — the
slice named as the trigger in issue #39. The MVP's static bearer token for the
user-facing API is the accepted baseline and is not evaluated here. User
accounts/RBAC are out of scope.

Method: four parallel research agents (Kubernetes bootstrap auth; CI-industry
runner auth + HashiCorp secret delivery; SPIFFE/SPIRE fit; network/host-layer
channel options), findings verified against the runner and control-plane code
where they made claims about Athanor. Sources are linked inline.

---

## TL;DR

- **Layer 1 verdict: the design holds up.** Boot Token → Session Token is the
  same TOFU-then-exchange shape as Kubernetes bootstrap-token → kubelet cert
  and sits at the GitHub-Actions-JIT maturity tier (single-use bootstrap →
  upgraded credential) — the best tier among bearer-token designs. The two
  properties that enabled the headline real-world attack on this pattern
  (reusable tokens, long TTLs — Synacktiv's AKS node-impersonation) are
  designed out. Four concrete, cheap gaps are worth carrying forward; none are
  MVP blockers.
- **Layer 2 verdict: SPIFFE/SPIRE is overkill at two hosts** — on consumer
  hardware its node attestation collapses to a join token (trust-equivalent to
  the static token you'd be replacing), and its differentiator (per-workload
  identity) is already solved by the Boot Token. The ranked shortlist for the
  remote-Provisioner slice: **Tailscale grants + Docker-over-SSH**, with a
  host-agent + private-CA mTLS as the principled later step once the raw
  Docker API stops being the interface.

---

## Layer 1 — Boot/Session Token vs prior art

### Where the design is equivalent or stronger

| Prior art | Athanor | Verdict |
|---|---|---|
| K8s bootstrap token: reusable, kubeadm default 24h TTL, ~85-bit secret | Boot Token: single-use (burned on first join), ~90s derived TTL, 256-bit | **Stronger.** Reuse + long life are exactly what the [AKS "So I became a node" attack](https://www.synacktiv.com/en/publications/so-i-became-a-node-exploiting-bootstrap-tokens-in-azure-kubernetes-service) exploited. |
| K8s: bootstrap token exchanges for a node credential; renewal uses a separate path | Boot Token exchanges for Session Token at first join; rejoin authenticates with the Session Token | **Good parity** — first-acquisition credential ≠ rejoin credential. |
| K8s NodeRestriction/Node Authorizer confine a bootstrapped node to its own slice | One runner per Job; Session Token bound to one Runner, dies at Job terminal state | **Equivalent intent, simpler mechanism.** The confinement K8s needs an admission plugin for, Athanor gets from ephemerality (ADR 0003). |
| AKS attack: token lets you mint *any* node's identity | Boot Token maps to one pre-created Runner record; join can't choose what it claims | **Designed correctly** — there is no name-forgery surface. |
| K8s de-facto 401/403 behavior (no formal oracle guarantee) | All failures collapse to generic `invalid_credentials` | **Stronger** — the validity oracle is explicitly removed. |
| GitLab's 16.0 migration away from shared registration tokens (untraceable, costly to rotate) | Boot Token is per-runner, control-plane-minted, single-use | Already on the good side of the migration GitLab had to make. |
| GitHub Actions JIT runner config: single-job credential, **delivered via env var**, 1h TTL | Boot Token via container env var, 90s TTL | Same delivery channel as the industry's best single-job design, with a tighter window. |

The industry maturity gradient for "agent proves itself to control plane":
shared long-lived token (Buildkite, old GitLab) → per-runner rotating token
(new GitLab) → single-use bootstrap exchanged for an upgraded credential
(GitHub JIT, **Athanor**) → no shared secret at all, control-plane-signed
identity (Nomad workload identity). Athanor sits one tier from the top; the
top tier is a post-MVP direction, not a gap.

### Gaps worth carrying forward (cheap, none MVP-blocking)

1. **Burned-token replay is a discarded tamper signal.** Vault
   response-wrapping's core lesson: single-use credentials are not just
   smaller-blast-radius, they are **tamper-evident** — if the legitimate
   client's unwrap fails, someone else got there first, and that is a security
   event ([Vault response wrapping](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping)).
   Athanor burns the Boot Token (good) but collapses a *second join with an
   already-burned token* into the same generic `invalid_credentials` as a typo.
   Keep the generic reply on the wire — but log/flag the burned-replay case
   distinctly on the control-plane side. Small change, real signal.

2. **Untrusted build steps inherit the runner's environment.** Verified in
   code: `executor/shell.go` runs steps via `exec.CommandContext` without
   setting `cmd.Env`, so the child inherits `ATHANOR_BOOT_TOKEN`. Today this
   is *mostly* harmless — the token is burned at join, before any step runs,
   so a step that reads it gets a dead credential. But it costs one line to
   `os.Unsetenv` after join (or pass a scrubbed `cmd.Env`), and it sets the
   right precedent before anything longer-lived ever lands in that
   environment. The **Session Token** is the credential that must never be
   step-reachable — today it lives only in runner process memory (correct;
   matches GitHub's runner keeping per-job tokens in the listener process,
   [auth design](https://github.com/actions/runner/blob/main/docs/design/auth.md)) —
   worth a one-line invariant in the protocol spec so rejoin work (issue #10)
   doesn't accidentally write it to disk or env.

3. **No server identity on the runner's dial.** K8s pins the API server's CA
   during bootstrap (`--discovery-token-ca-cert-hash`) — TOFU covers the
   *server's* identity too. Athanor's runner dials `ws://` with
   `websocket.DefaultDialer` (verified, `protocol/client.go`); on a single
   host this is fine, but a runner pointed at a rogue endpoint would hand its
   Boot Token to an attacker who can replay it within the 90s window. The fix
   arrives naturally with the remote host: the dial becomes `wss://` (default
   dialer already verifies TLS) or rides an authenticated tunnel (layer 2).
   Flag it as a named precondition of the remote-host slice rather than work
   to do now.

4. **Token prefixes for secret scanning.** GitLab prefixes runner tokens
   (`glrt-`) so leaked tokens are machine-recognizable
   ([GitLab token docs](https://docs.gitlab.com/security/tokens/)). An
   `athanor_boot_` / `athanor_sess_` prefix is nearly free and pays off the first
   time a token lands in a log or a pasted bug report.

### Explicitly fine because runners are single-job ephemeral

- **Env-var delivery of the Boot Token** — single-use + 90s TTL + burn-before-
  build-steps neutralizes the classic env-var leak vectors (`docker inspect`,
  `/proc/*/environ`, child inheritance); GitHub ships JIT config the same way.
- **No token rotation** — single-use tokens don't rotate; the Session Token
  dies with the Job.
- **No NodeRestriction-style confinement layer** — one-runner-per-job already
  is the confinement.
- **Bearer Session Token instead of proof-of-possession** (GitHub's runner
  holds an RSA key that never crosses the wire; Nomad mints signed JWTs).
  Structurally weaker, but bounded by job lifetime + TLS. This is the honest
  answer to "what would the top maturity tier look like" — a post-MVP
  exploration, not a gap to fix.

---

## Layer 2 — trusting the remote runner host

The decision this feeds: the slice that points the Provisioner at the
bare-metal mini PC (the named trigger for issue #39's orphan reconciliation).
The threat to organize around: **the Docker Engine API is root-equivalent** —
whoever can reach it owns the runner host
([Docker: protect the daemon socket](https://docs.docker.com/engine/security/protect-access/)).
Every option below is about who can reach that endpoint and whether the
channel is authenticated. A secondary fact that simplifies everything: once
the Provisioner is remote, the Boot Token transits the network inside the
container-create call — but **any** encrypted channel (TLS, SSH, WireGuard)
protects it adequately, and its single-use/90s properties already cap
interception. The channel choice is about the root-equivalent API, not the
token.

### SPIFFE/SPIRE: the honest answer is overkill — for specific reasons

1. **At two hosts, its incremental security over a private CA is ~zero.** Its
   differentiators are attested node identity and per-workload identity. On a
   consumer mini PC the only workable node attestor is `join_token` —
   trust-equivalent to the static token you'd be replacing (the TPM attestor
   needs a DevID cert consumer hardware doesn't ship with; cloud attestors
   need a cloud). And per-workload identity for runners is already solved by
   the Boot Token.
2. **The operational tax lands on one person:** server + agent lifecycle, a
   datastore, *manual* registration-entry management (the Kubernetes
   controller that automates this is deliberately out of the runner path),
   trust-bundle distribution, and no Elixir client — the control plane would
   shell out to a socket. No first-hand account of a happy 2-host homelab
   SPIRE deployment surfaced; the ecosystem is K8s/multi-cloud, which is
   itself a fit signal.
3. **The tempting idea — docker workload attestation replacing the Boot Token —
   fights the grain of one-shot containers:** attestation latency on the
   critical path of every job, a [documented startup race](https://github.com/spiffe/spire/issues/1230)
   whose community workaround is a poll-loop before the real command, and
   per-job registration churn that reinvents the Boot Token with more moving
   parts. SPIRE is built for long-lived services that rotate for hours, not
   90-second boots.

**Revisit when:** runner hosts exceed one (warm pool, second machine), infra
goes heterogeneous/cross-cloud, or hardware with real attestation roots shows
up. **Firecracker alone is not a trigger** — SPIRE has no microVM-specific
attestor; a microVM would be attested by… a join token injected at boot,
i.e. the Boot Token pattern again. If the learning itch is identity systems,
**step-ca** delivers the same concepts (private CA, short-lived certs,
automatic renewal, mutual identity) at a tenth of the moving parts.

### Ranked options for the Provisioner→host channel

1. **Tailscale grants as the reachability boundary + Docker-over-SSH on top.**
   Fits the homelab trajectory (mesh already plausible). A grant restricts
   *which node* may reach the Docker port at all — deny-by-default, the port
   never exposed to the LAN; SSH carries the root-equivalent API. Tailscale
   SSH makes the SSH layer keyless (auth rides node identity); `tsnet` gives a
   future Go host-agent an embedded node with caller identity via `WhoIs`.
   Honest limit, per Tailscale's own docs: the tailnet gates **reachability,
   not per-action authorization** — a compromised node inside the mesh uses
   exactly the access it was granted. Direct prior art for the SSH leg:
   GitLab's fleeting autoscaler drives remote instances over SSH in
   production.
2. **Docker-over-SSH alone.** The minimal, official, modern-default answer
   for one remote host (`docker -H ssh://`): no new ports, no CA, one SSH
   key. The Docker docs position TLS-with-certs as the
   advanced/many-clients path. A tailnet layers on later without changing
   anything. One Go-specific note: the Docker SDK over SSH shells out to a
   local `ssh` binary, where the TLS transport is native to the SDK.
3. **Plain WireGuard + SSH.** If avoiding the Tailscale dependency matters.
   At exactly two static LAN nodes, Tailscale's headline value (NAT traversal,
   key distribution) is moot — what you'd actually give up is the
   grants/identity/tsnet layer, not connectivity.
4. **Host-agent + step-ca mTLS — the principled later step.** Every option
   above grants all-or-nothing root (Docker TLS is explicitly "not a granular
   access control mechanism"). True least privilege — "you may boot and
   destroy runners, nothing else" — requires a narrow purpose-built API on
   the host instead of the raw Docker socket. That host-agent is plausibly
   the same slice that absorbs Firecracker control later, and it's where
   issue #39's reconciliation loop would naturally live. Premature before the
   raw-Docker-API phase has taught what the agent's API should be.
5. **Docker TCP+TLS client certs, standalone.** Works and the Go SDK speaks
   it natively, but for one host it's strictly more cert management than SSH
   for the same all-or-nothing grant.
6. **TPM host attestation — defer.** In a physically-controlled two-machine
   homelab, the attacker attestation defends against (tampered/swapped host)
   is mostly absent, and frameworks like Keylime are heavyweight with
   [documented foot-guns](https://puiterwijk.org/posts/tpm2-attestation-keylime-vulnerability/).
   The cheap, real TPM win if ever wanted: `systemd-creds`/TPM-bound LUKS for
   secrets-at-rest on the runner host.

### A pattern worth studying before designing the remote-Provisioner slice

GitHub Actions runner scale-sets invert the direction: the host runs an
outbound long-poll **listener**, the control plane never reaches into the
host, and each job's runner boots with a JIT credential and dials out
([ARC docs](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)).
Athanor's runner half already matches (Boot Token + WebSocket dial-back); the
open design question for the remote slice is whether the *boot trigger*
should eventually become pull-based too — a host-agent that polls or holds a
channel to the control plane would mean **no inbound root-equivalent access
to the runner host at all**, and would collapse options 1–5 into "the
host-agent dials out like a runner does." That's a grilling-session question,
not a research conclusion.

---

## Source index

Layer 1: [K8s TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/) ·
[K8s bootstrap tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/) ·
[K8s Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/) ·
[Synacktiv AKS bootstrap-token attack](https://www.synacktiv.com/en/publications/so-i-became-a-node-exploiting-bootstrap-tokens-in-azure-kubernetes-service) ·
[GitHub Actions runner auth design](https://github.com/actions/runner/blob/main/docs/design/auth.md) ·
[GitHub JIT runners](https://github.blog/changelog/2023-06-02-github-actions-just-in-time-self-hosted-runners/) ·
[GitLab runner-token migration](https://docs.gitlab.com/ci/runners/new_creation_workflow/) ·
[Buildkite agent tokens](https://buildkite.com/docs/agent/v3/tokens) ·
[Vault response wrapping](https://developer.hashicorp.com/vault/docs/concepts/response-wrapping) ·
[Nomad workload identity](https://developer.hashicorp.com/nomad/docs/concepts/workload-identity) ·
[GitHub Actions secure-use reference](https://docs.github.com/en/actions/reference/security/secure-use)

Layer 2: [Docker: protect the daemon socket](https://docs.docker.com/engine/security/protect-access/) ·
[Tailscale grants](https://tailscale.com/docs/reference/grants-vs-acls) ·
[Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) ·
[tsnet](https://pkg.go.dev/tailscale.com/tsnet) ·
[Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock) ·
[SPIRE concepts](https://spiffe.io/docs/latest/spire-about/spire-concepts/) ·
[SPIRE join-token attestor](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_jointoken.md) ·
[SPIRE docker workload attestor](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_workloadattestor_docker.md) ·
[SPIRE short-lived-workload race](https://github.com/spiffe/spire/issues/1230) ·
[SPIRE operational-cost account (vendor, claims corroborated by SPIRE docs)](https://aembit.io/blog/everyone-wants-spiffe-almost-no-one-can-afford-to-build-it-right/) ·
[step-ca](https://smallstep.com/docs/step-ca/) ·
[GitLab fleeting](https://docs.gitlab.com/runner/fleet_scaling/fleeting/) ·
[GitHub ARC / runner scale-sets](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller) ·
[Keylime TPM foot-guns](https://puiterwijk.org/posts/tpm2-attestation-keylime-vulnerability/)
