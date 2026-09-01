# Changelog

All notable changes to hecate-graph will be documented in this file.

## [0.3.0] - 2026-09-01

### Added

- Phase 2 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): `learn_truths_from_mesh`,
  a passive subscriber to a new shared, opt-in `truth_asserted` topic
  (`{subject, predicate, object}`, flat name matching `entity_learned`/
  `link_learned`'s own sibling style -- not the "mesh.truth_asserted"
  dot-namespaced guess the plan drafted before checking real topic
  conventions on this mesh). Calls the exact same `learn_link:learn/2`
  entry point the RPC path already uses -- no new write path -- with
  the mesh `publisher` filling `learn/2`'s `Caller' slot, so the
  publisher becomes a graph entity exactly like an RPC caller does in
  Phase 1.
- Confidence is set by provenance quality, not the fact's own optional
  claim: `publisher_verified = true` -> 0.7, `not_signed` -> 0.4,
  `false` (signature present but INVALID) -> rejected outright, not
  recorded at a lower confidence -- the plan's own table has no row for
  this case. Requires macula >= 10.16.0 for `publisher_verified` to be
  anything but the safe `not_signed' fallback.
- 5 new tests, 30 total.

### Fixed

- edoc/ex_doc had never successfully built for this repo (confirmed by
  checking out the pre-Phase-1 commit and re-running -- same failures).
  Two root causes, both documented gotchas in this workspace's own
  CLAUDE.md that nobody had caught here yet: Markdown-style double
  backtick quoting (`` `word` ``) instead of EDoc's backtick-then-
  single-quote convention (`` `word' ``) in several module docs, and a
  `<<"...">>` Erlang binary literal inside `hecate_graph_facts`'s
  moduledoc breaking the XML parser. `rebar3 ex_doc` now succeeds
  cleanly.
- `rebar3 lint` (elvis) had never been run against this repo either --
  fixed one real `no_deep_nesting` finding in the new
  `learn_truths_from_mesh` module.

## [0.2.0] - 2026-09-01

### Added

- Phase 1 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): `learn_link` now records
  the RPC caller as a graph entity, asserted-linked to both the subject
  and object it just told the graph about (`caller --asserted-->
  subject`, `caller --asserted--> object`), at confidence 1.0. Reuses
  the existing `ensure_entity`/`insert_link` machinery, zero schema
  change. Requires macula >= 10.15.0 + hecate_om >= 0.22.0 (bumped in
  this release); against an older macula, `caller` reads `undefined`
  and provenance is skipped entirely -- not a hard dependency, a
  graceful no-op.
- 2 new tests (`learn_link_records_caller_provenance`,
  `learn_link_no_provenance_without_caller`), 25 total.

### Fixed

- `identity_key_path` was never configured in the deployed image's
  `sys.config.src`, so `hecate_om_identity:keypair/0` stayed `{error,
  no_keypair}` forever and capability advertisement silently no-oped on
  every republish tick -- the service looked healthy (`/health` OK,
  connected, held a valid realm) while being completely unreachable on
  the mesh. Found live on msi00 after running healthy, invisible, for
  47+ minutes. Same bug class hecate-mail/hecate-tube/hecate-rag had
  already hit; this mirrors their fix.

## [0.1.0] - 2026-09-01

### Added

- Initial scaffold: CozoDB NIF (Rust/Rustler) + Erlang OTP app
- `learn_link` procedure: record a relationship, implicitly create entities,
  publish `entity_learned` and `link_learned` facts
- `resolve_link` procedure: direct, filtered, N-hop recursive traversal
- `resolve_entity` procedure: entity attributes + link summary (out/in degree)
- Mesh procedure registration via `hecate_om_service` behaviour
- 20 unit tests with meck mocking (CozoDB NIF not required for tests)
- Containerfile, README, elvis config
