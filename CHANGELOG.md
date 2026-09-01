# Changelog

All notable changes to hecate-graph will be documented in this file.

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
