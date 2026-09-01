# hecate-graph

**An embeddable relational-graph database as a mesh service.** Each instance
runs its own [CozoDB](https://github.com/cozodb/cozo) (Datalog + RocksDB) on
local disk and exposes mesh procedures for querying and learning associations.
Consumers compose knowledge graphs from distinct sources by calling
`resolve_link` across instances and/or subscribing to the `entity_learned` /
`link_learned` fact streams.

## Mesh surface

| Channel | Type | Purpose |
|---------|------|---------|
| `hecate_graph.resolve_link` | `mesh_call` | Query links for an entity (direct, filtered, N-hop traversal) |
| `hecate_graph.resolve_entity` | `mesh_call` | Query entity attributes + link summary |
| `hecate_graph.learn_link` | `mesh_call` | Record a relationship (implies `entity_learned` for new entities) |
| `entity_learned` | `mesh_publish` | A new entity was implicitly created |
| `link_learned` | `mesh_publish` | A new relationship was recorded |

## learn_link: implicit entity creation

`learn_link(subject, predicate, object, metadata)` upserts both entities
and the link. If an entity didn't exist before, `entity_learned` is published
for it. Then `link_learned` is published for the link. A consumer watching
both topics builds a composed knowledge graph incrementally.

## CozoDB

CozoDB is a transactional, relational-graph-vector database that uses Datalog
for queries. It supports recursive traversal, shortest path (Dijkstra),
PageRank, HNSW vector search, and time travel — all embedded as a Rust NIF
via [Rustler](https://github.com/rusterlium/rustler).

The NIF is optional at build time: if the Rust toolchain is not available,
the Erlang wrapper returns `{error, nif_not_loaded}`. There is no pure-Erlang
fallback for a graph database.

## Build

```sh
rebar3 compile
rebar3 lint
rebar3 ct
rebar3 as prod release
```

## Configuration

| Variable | Default | What |
|---|---|---|
| `HECATE_NODE_NAME` | `hecate_graph` | Erlang node name |
| `HECATE_NODE_HOST` | `127.0.0.1` | Erlang node host |
| `HECATE_COOKIE` | `hecate_graph` | Erlang cookie |
| `HECATE_HEALTH_PORT` | `8482` | Health endpoint port |
| `HECATE_REALM` | (required) | Mesh realm |
| `HECATE_GRAPH_DATA_DIR` | `/var/lib/hecate-graph` | CozoDB (RocksDB) data directory |

## License

Apache-2.0
