# Plan: Mesh Truths, Provenance, Narration & Reputation

**Status:** Draft — v1.0
**Created:** 2026-09-01
**Last Updated:** 2026-09-01
**Scope:** hecate-graph's own evolution. Phase 1 depends on one small, scoped
fix in `macula-io/macula` (an owned dependency); later phases depend on
`macula-io/macula-architecture`'s
`PLAN_CITIZEN_IDENTITY_AUTHN_AUTHZ.md` landing first.

## Overview

This exists so hecate-graph's knowledge grows from what actually happens on
the mesh, not just from what one caller decides to tell it directly — with
enough provenance attached that "grown organically" doesn't mean "grown
untrustworthy."

## Current State (baseline, live on msi00 as of this plan)

- Three mesh RPC procedures: `hecate_graph.learn_link`, `.resolve_link`,
  `.resolve_entity` — pull-only ingestion, a caller must know hecate-graph
  exists and call it directly.
- Two published facts: `entity_learned`, `link_learned` — push-out only, for
  other graph instances to compose from.
- No subscribe-side ingestion at all.
- Every entity/link's `source` field is a hardcoded constant
  (`hecate_graph_facts:reporter/0` → `<<"hecate-graph">>`), not the real
  caller or publisher identity. There is currently no way to ask "who told
  the graph this."

## Phase 1 — The Caller (and Publisher) Becomes Part of the Graph

**RPC side.** `learn_link`'s `source` should be the actual calling identity,
not a constant naming this service.

- Verified this session (read directly, not assumed):
  `macula-io/macula`'s CALL frame already carries
  `caller := macula_identity:pubkey()` as a **required** wire field
  (`macula_frame.erl`). The identity is not missing from the protocol.
- The actual blocker: `macula_response.erl`'s `handle_request/2` callback —
  the framework layer every RPC handler in this codebase implements — does
  not thread `caller` through to the application handler at all (grepped the
  whole module and `macula_station_link.erl`: zero references). This is a
  contained, owned-library fix, not a protocol change — surfacing data
  that's already on the wire, not adding new data to it.
- Once available: `learn_link` inserts `caller --asserted--> subject` and
  `caller --asserted--> object`, reusing the *existing* `links` mechanism —
  zero schema change. The caller becomes a normal graph entity, queryable
  the same way as anything else ("what has hecate-mail ever told the
  graph" is just `resolve_link(hecate-mail-entity, direction=out,
  predicate=asserted)`).
- **Explicitly out of scope for Phase 1:** full per-triple reification
  (`caller --asserted--> THIS SPECIFIC link`, not just its endpoints). The
  coarser "caller touched these entities" is the YAGNI-correct start; full
  reification needs unifying the entity/link ID spaces or a dedicated
  provenance table, and isn't worth building until something actually needs
  to ask "who said this exact fact," not just "who's talked about this
  entity."

**Pub/sub side.** Already in noticeably better shape than RPC — verified
directly in `macula_frame.erl` and `macula_pubsub.erl`:

- `PUBLISH`/`EVENT` frames carry `publisher := macula_identity:pubkey()`
  (required) **plus an optional `publisher_sig`** — a real Ed25519
  signature (`sign_publisher/2`/`verify_publisher/1` already exist in the
  SDK) that survives multi-hop gossip relay, unlike raw transport-peer
  auth, which only proves who most recently forwarded you something.
- `macula_pubsub:subscribe_callback/4`'s callback is typed
  `fun(Topic, Payload, Meta)`, and `Meta` already contains `publisher` —
  both the raw `{macula_event, ...}` mailbox API and the supervised
  callback API expose it today. No fix needed on the Erlang side for this
  path.
- `publisher_sig` is optional on the wire (not every publish is signed).
  Whether a given fact carries a *verified* signature or just a claimed,
  unsigned `publisher` field is the natural confidence-tier signal for
  Phase 2 below.

**Cross-SDK note.** Neither `caller` nor `publisher`/`publisher_sig` is a
*new* wire addition — both already exist in the frame spec every SDK must
implement. Using them from hecate-graph shouldn't require a protocol
version bump. What's genuinely unverified: whether `macula-go`,
`macula-rust`, `macula-dotnet`, `macula-php` already surface `Meta`/
`publisher` through their own subscribe APIs the way Erlang's does, or
silently drop it the way `macula_response.erl` currently drops `caller`.
This is a parity audit across four SDKs, not a coordinated breaking
rollout — worth doing before any cross-SDK service depends on it being
universal (at minimum `macula-rust` and `macula-go` are real, in-use SDKs
today, not Erlang-only theory — see `macula-apps/macula-passport` and
`macula-apps/macula-cam2me`).

## Phase 2 — Subscribe to a Well-Known "Truths" Topic

- One canonical wire contract for a shared topic (name TBD, candidate:
  `mesh.truth_asserted`, matching the verb-not-CRUD naming convention):
  `{subject, predicate, object, confidence?, source?}`. Willing publishers
  opt in explicitly to this shape.
- **Deliberately not** parsing arbitrary existing domain events
  (`hecate-mail`'s `message.sent`, `hecate-tube`'s `video.published`,
  etc.) — a translator-per-producer doesn't scale and recouples
  hecate-graph to everyone else's wire formats. One shared contract,
  opt-in.
- New desk (subscriber) — working name `learn_truths_from_mesh` — that
  calls the *same* `ensure_entity`/`insert_link` machinery `learn_link`
  already has. No new write path, just a new entry point into the existing
  one.
- Confidence weighted by provenance quality, not flat 1.0 for everything:

  | Source | Confidence (starting point, tune later) |
  |---|---|
  | Direct RPC, caller identity threaded (Phase 1) | 1.0 |
  | Pub/sub, `publisher_sig` present and verified | ~0.7 |
  | Pub/sub, `publisher` present but unsigned | ~0.4 |

- The publisher becomes a graph entity here too, exactly like Phase 1's RPC
  caller (`publisher --asserted--> subject/object`) — unifying both
  ingestion paths onto one provenance model instead of two.

## Phase 3 — Raw vs. Prose as Separate Desks (not a format flag)

Pushed back on and corrected mid-design: these must NOT be one procedure
with a `format` parameter. An LLM-backed call has a fundamentally different
cost/latency/failure profile than a local Cozo query, and bundling them
would make one procedure's latency bimodal, and would stop a realm operator
from disabling narration (cost/sovereignty/latency) while keeping raw
queries live.

- **Raw:** what already exists (`resolve_link`/`resolve_entity`), unchanged.
- **New desk** — working name `narrate_graph` — wraps `resolve_entity`/
  `resolve_link` internally as plain Erlang function calls (no mesh
  round-trip, no new query logic) and hands the result to a pluggable
  backend:

  ```erlang
  -callback narrate(Subgraph :: map(), Opts :: map()) ->
      {ok, binary()} | {error, term()}.
  ```

  Default implementation backed by **Melious** (EU-sovereign) — never a
  Big Tech LLM API, per this workspace's own sovereignty stance; the
  backend is swappable via config, not hardcoded to Melious specifically.
- Advertised as its **own** `hecate_om_capabilities` entries
  (`hecate_graph.narrate_entity` / `.narrate_link`), independent of the
  raw procedures, so a realm operator can disable narration alone.
- Worth a deterministic fallback (simple sentence-per-triple templating) if
  the narrator backend is unreachable — matching the graceful-degrade
  precedent this codebase already has for the CozoDB NIF itself
  (`{error, nif_not_loaded}`, never a hard crash) — rather than hard-failing
  the whole call when Melious is down.

## Phase 4 — Citizen Lookup (nice to have, likely near-free once built)

Not new hecate-graph logic on its own: this is a UCAN proof-chain walk (does
a caller/publisher DID's delegation trace back to a passport-anchored
citizen root), which is `PLAN_CITIZEN_IDENTITY_AUTHN_AUTHZ.md`'s concern,
not this repo's. The convergence worth keeping in mind: if identity
delegation events ever get published as facts too (the same Phase 2
mechanism, extended from domain relations to identity events), "which
citizen is behind this DID" stops being special-cased code and becomes
`resolve_link(caller_entity, predicate="delegated_by", direction=out)` —
the exact same traversal as everything else. Depends on that plan's own
Phase 1–2 landing first; nothing to build here until then.

## Phase 5 — Reputation (exploratory — real technical fit, not scoped to build)

CozoDB — hecate-graph's own storage engine — ships **built-in PageRank**.
Trust propagation over an assertion graph (`caller --asserted-->` edges
from Phase 1/2) is close to the textbook use case for exactly that
algorithm family (EigenTrust-style P2P reputation is PageRank-derived).
This is a concrete technical fit worth naming, not aspiration.

Real open questions before this is buildable, not just "nice future work":

1. **Negation isn't representable yet.** The schema has no way to say
   "caller B disputes what caller A asserted" — only independent
   assertions that happen to agree or don't. Corroboration-counting works
   today; contradiction-detection needs a schema extension.
2. **Sybil resistance should ride the realm trust-ladder, not invent its
   own.** A `provisional`-tier caller's corroboration shouldn't count the
   same as a `foundation-member`'s — this is exactly why
   `PLAN_PROVISIONAL_REALM_TIER.md` exists; weight by tier rather than
   build a second Sybil defense from scratch.
3. **Batch, not live.** PageRank-style algorithms are iterative and global
   — recompute on a schedule and cache, not recompute per
   `resolve_entity` call.

## Cross-Repo Dependencies

| Repo | What's needed | Status |
|---|---|---|
| `macula-io/macula` | `macula_response.erl`: thread `caller` through to `handle_request/2` | Not started — small, scoped, owned-library fix. **The one concrete, ready-to-build piece today.** |
| `macula-io/macula-go`, `-rust`, `-dotnet`, `-php` | Parity audit: does each SDK's subscribe API already expose `Meta`/`publisher`? | Not checked |
| `macula-io/macula-architecture` (`PLAN_CITIZEN_IDENTITY_AUTHN_AUTHZ.md`) | Delegation-as-facts, for Phase 4 | Depends on that plan's own earlier phases |

## Open Decisions

| # | Decision | Leaning | Why still open |
|---|---|---|---|
| 1 | Truths topic name | `mesh.truth_asserted` | Not checked against any existing topic-naming registry/convention beyond the general verb-not-CRUD rule |
| 2 | Exact confidence values per provenance tier | See Phase 2 table | Starting points, not measured; tune once real traffic exists |
| 3 | Narrator backend selection mechanism | Config/env var, not hardcoded to Melious | Exact config shape not designed |
| 4 | Negation/contradiction representation | Not designed | Needed before Phase 5 is buildable at all, not just before it's good |

## Phases Summary

- [x] **Phase 1** — Caller/publisher as graph entities. DONE 2026-09-01:
      the actual blocker was `macula_station_link.erl`'s `handle_inbound_call/2`
      (not `macula_response.erl` as this section guessed before checking —
      it decoded the frame and dropped `caller` before `macula_response`
      ever saw the payload). Fixed by merging `caller` into `Payload`
      rather than changing `handle_request/2`'s arity, so none of the
      6+ other repos implementing it needed to change at all (macula
      10.15.0, hecate_om 0.22.0's `hecate_om_wire:caller/1`, hecate-graph
      0.2.0's `learn_link`).
- [x] **Phase 2** — Subscribe to a well-known truths topic, confidence
      tiered by provenance quality. DONE 2026-09-01: topic is
      `truth_asserted` (flat, unprefixed — matching `entity_learned`/
      `link_learned` and every other real topic on this mesh, not the
      "mesh.truth_asserted" guess above). Also needed a second small
      macula fix (10.16.0) — `publisher_verified` was computed in
      `on_inbound_event/5` and discarded before reaching subscribers,
      the same class of gap as Phase 1's `caller`, just one layer over.
      An INVALID signature (present but failed verification) is rejected
      outright, not recorded at a lower confidence — the table above has
      no row for it because Phase 1 can't reach that state on the RPC
      side. hecate-graph 0.3.0.
- [ ] **Phase 3** — `narrate_graph` as a separate, pluggable-backend desk
- [ ] **Phase 4** — Citizen lookup via delegation-facts traversal (depends
      on the citizen-identity plan)
- [ ] **Phase 5** — Reputation via CozoDB's built-in PageRank (exploratory;
      three open questions above need answers first)
