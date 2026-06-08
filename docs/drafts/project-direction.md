# Project direction & decision framework

> Working notes from a 2026-06-08 planning session. Not Athanor scope per se — this
> is cross-project direction-setting: what to build next, and a reusable filter for
> deciding what's safe to build. Lives in `drafts/`; promote/relocate once it
> stabilizes (n=1 right now).

## Context

- I'm a junior engineer at an **AI Scribe (healthtech) company**. Primarily Elixir;
  comfortable in Go and TypeScript. Side projects are **learning vehicles**, not
  businesses (same spirit as Athanor's CLAUDE.md).
- My employer's specific features/roadmap are deliberately **not enumerated here** —
  the overlap filter below handles them case-by-case rather than committing them to
  a doc.

## Goals (what these projects are for)

1. **Systems / distributed-systems depth** — the thing the day job won't teach me.
2. **Product intuition** — "knowing what to build"; leverage through impact, not output.
3. **Progress toward senior** — see the senior note below.
4. Portfolio — a nice-to-have, already covered by the safe public work.

## The two-lane model

Run two concurrent tracks of different cognitive load:

- **Lane 1 — deep / hands-on / comprehension.** Slow, deliberate; active grilling +
  FMA. The goal *is* understanding. **Never AFK this.** (e.g. the Firecracker stack.)
- **Lane 2 — lower-thinking / AFK.** Front-loaded design (grill → docs → issues),
  then delegate the build to AFK agents. The goal is product intuition + leverage,
  *not* implementation comprehension. (e.g. the Canny clone.)

Governing principle (learned the hard way on Athanor — went too fast, comprehension
fell behind, paused to learn FMA):

> **Match the mode to the goal. Go fast only where comprehension isn't the point.**
> Keep your hands on the part where the learning lives; delegate the rest. This is
> fractal — it holds *across* lanes and *within* a lane (in Lane 2 you keep the
> product grill, delegate the CRUD).

Corollary — **failure-mode density is a lane classifier:** high density → Lane 1
(you *want* to reason through them); low density → Lane 2 (safe to delegate).

## The overlap filter (the durable bit)

Side projects must not collide with employer IP / conflict-of-interest.

**Three tests — clear only if it passes all three:**
1. **Domain distance** — the *valuable* part isn't in the employer's space
   (healthcare/clinical, speech-to-text/ASR, AI-over-language).
2. **Framing** — organized around a *generic skill*, not "the feature we'll need."
3. **Use/integrate ≠ build/sell** — consuming a software category is fine; the
   employer *building or selling* it, or a colleague *actively building* it, is not.

**What does NOT make something safe (surface, not substance):**
- A **private repo** — addresses competitive *exposure*; does nothing for IP / COI /
  trade-secret reuse (those are visibility-independent).
- A **different language** — prevents accidental code copying and helps *demonstrate*
  separation, but design/concept reuse is language-independent.
- **"I thought of it first" / front-running** — timing isn't a defense; still an
  employee, still related to the business.
- **Speculation about a future pivot** — not a constraint. The filter tests what *is*
  (build/sell/active-workstream *now*), not what the company might hypothetically do
  years out. Speculating yourself into paralysis is the failure mode.

**What actually makes it safe (substance):**
- Model a **non-employer-domain example** (generic SaaS, repo permissions, etc.).
- Build **only from public sources**; never port employer designs/requirements.
- Confirm it's **not an active internal workstream** — and when unsure, **ask, don't
  hide** (raising it at work converts risk into initiative; for a junior, pure upside).

## Locked-in plan

- **Lane 1 — Firecracker stack:** Athanor (CI control plane) → ephemeral sandbox
  worker → fly.io-style clone. The primary distsys / Firecracker track.
- **Lane 2 — Canny clone** (customer-feedback / roadmap tool): a product-intuition rep
  via grill → docs → issues → AFK. **Guardrail: keep it AI-free** (no AI-on-text); the
  product is the judgment calls (dedup/merging, the "graveyard" problem,
  transparency-vs-flexibility), not the CRUD. Handoff prompt already drafted.
- **Parked:** rolling my own database (see DB note); Loom clone (see Loom note).
- **Filed:** Raft as a standalone learning project — GitHub issue **#87**.

## Project backlog (by lane / muscle)

**Crossover (systems depth + product intuition in one):**
- Privacy-friendly web analytics (Plausible/Fathom) — product surface + a real data
  pipeline; the safe way to scratch the columnar/analytics-DB itch (*use* a columnar
  DB, don't build one).
- Feature flags (LaunchDarkly) — targeting rules + SDK DX + real-time push (Channels).
- Error tracking (Sentry-lite) — grouping/dedup as the product insight. (Keep AI-free.)

**Deep-systems (Lane 1):**
- Distributed log / mini-Kafka; Dynamo-style KV (consistent hashing, gossip, quorum);
  Raft (#87).

**Different deep flag (orthogonal, non-systems-level):**
- Interpreter → compiler (*Crafting Interpreters*); emulator / ray tracer (fun).
- *(Columnar/OLAP engine withdrawn — it required the systems-level / Rust grind I've
  ruled out.)*

**Fresh territory:**
- Local-first / CRDT sync engine; search engine / inverted index.

**Meta (compounds with everything):**
- Parallel-agent run-plan executor (Athanor issue #76 territory) — orchestrate Claude
  agents across worktrees; it's the engine that runs the Lane-2 AFK work.

**More clones (Lane 2):**
- Dub (link mgmt, lowest load); form builder (Tally); Linear/Trello (taste/polish —
  keep hands-on, bad AFK fit).

## Databases (interested, but no systems-level / no Rust)

Channel the interest into the non-systems-level slices — *which one TBD*:
1. **Data-intensive product** (analytics clone) — use a DB, don't build one. *Best
   fit; rides the Lane-2 / product lane.*
2. **Distributed / coordination side** — replicated KV, sharding, consensus-backed.
3. **Query-engine architecture** in a high-level language (parser → planner →
   executor) — algorithmic, not byte-level.
4. **Deep Postgres mastery** — indexing, partitioning, logical replication, extensions.

Reframe: a DB project's "systems-level-ness" is a choice of language + goal. Built in
Elixir/TS for *architecture* understanding = applied CS, not systems programming.

## Problem domains that interest me

- **Correctness-under-failure (my taste):** durable execution / workflow engines
  (Temporal-style), ledgers / money movement (double-entry, idempotency — TigerBeetle
  ref), real-time collab / local-first (CRDTs), messaging/delivery infra, data
  infrastructure.
- **Fresh / fun:** game backends (real-time state sync; Elixir showcase),
  geospatial / logistics, homelab / IoT / time-series, creative coding / simulation,
  privacy & security tooling.

## Authz (ReBAC / Zanzibar)

A good, safe project **if kept generic** — its core (relationship-graph `check`,
consistency / the "new enemy" problem) is rich and distsys-flavored, valuable
independent of any domain. Guardrails: model a **non-clinical example domain**, build
from **public sources** (Zanzibar paper, SpiceDB/OpenFGA/Oso), confirm it's **not an
active internal workstream**. **Go** is a natural fit (SpiceDB & OpenFGA are Go).
Picking Go for *separation* is the wrong reason (surface, not substance) — pick it for
ecosystem/learning; separation is a free side-benefit.

## Loom verdict — parked

Video-only (transcription/AI stripped) would be *safe* — the overlap is the
transcription/ASR layer, **not** the video. But the media pipeline
(capture/upload/transcode/stream) is **failure-mode-dense** → wrong shape for the AFK
lane (which wants engineering-easy / product-hard). Belongs in Lane 1 if anywhere, but
loses that slot to higher-aligned work. A clean illustration of the
failure-mode-density classifier.

## Tech stacks

- **Lane 2 / AFK / clones → TypeScript** (best agent productivity; the language is a
  transparent tool here). Use **Deno** (or strict dep hygiene + `--ignore-scripts`)
  for the npm supply-chain concern; **codify an approved-deps policy** for agents
  (they'll happily `npm install` anything).
- **Lane 1 / deep → Go or Elixir** (Rust ruled out — don't want systems-level).
  Elixir for the distsys-flavored items (PubSub/Channels/OTP sweet spot); Go for
  ecosystem fit (Firecracker/containers) and authz reference implementations.
- **DB-flavored → Elixir or TS** (high-level, architecture-focused).
- **Python → on demand only** — its edge (data/ML) sits in the no-go domain.
- Don't stack a new language *and* a new hard domain at once unless deliberate.

## Senior note

Senior is mostly **not** "more topics" — it's judgment, scope, owning *outcomes*,
communication, operating in production, and multiplying teammates. The technical stem
is necessary but rarely the bottleneck. At a 4-person startup there's no rubric, so:
- Use **open rubrics as an external calibration mirror** — engineeringladders.com
  (radar / sphere-of-influence; good for solo self-assessment), progression.fyi
  (directory of real ladders), the CircleCI competency matrix.
- Likely gaps to target: **production ownership / operability** (side projects can't
  teach the 3am page — run Athanor *for real*) and **outward communication** (turn the
  strong design-doc habit toward driving team alignment).
- Read **Designing Data-Intensive Applications** — fits the distsys + DB interests.

## Open questions / next actions

- Decide **which database slice** (the 4 above) to pursue, and which lane it rides.
- Settle the **authz "active workstream?"** question before starting it.
- **Canny:** handoff prompt drafted; ready to start grill → docs → issues on the main PC.
- **Raft** filed as #87.
