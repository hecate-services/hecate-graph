%%% @doc Hecate Graph — implements the hecate_om_service behaviour.
%%%
%%% An embeddable relational-graph database backed by CozoDB (Datalog +
%%% RocksDB). Each instance runs its own local CozoDB and exposes mesh
%%% procedures for querying and learning associations.
%%%
%%% Mesh surface:
%%%   hecate_graph.resolve_link    — query links for an entity
%%%   hecate_graph.resolve_entity   — query entity attributes
%%%   hecate_graph.learn_link      — record a relationship (implies entity_learned)
%%%   hecate_graph.narrate_entity  — LLM prose description of an entity (Phase 3)
%%%   hecate_graph.narrate_link    — LLM prose description of a subject's links (Phase 3)
%%%
%%% narrate_* are their own capabilities, independent of resolve_* —
%%% `narration_enabled' (app env, default true) lets a realm operator
%%% turn narration off alone (cost/sovereignty/latency) while keeping
%%% raw queries live. See hecate_graph_narrator's own moduledoc for why
%%% these are separate desks, not a `format' flag on resolve_*.
%%%
%%% Fact streams:
%%%   entity_learned  — published when a new entity is implicitly created
%%%   link_learned    — published when a new link is recorded
%%%
%%% Consumers compose a knowledge graph from distinct sources by:
%%%   1. Calling resolve_link across instances via mesh_call (pull)
%%%   2. Subscribing to entity_learned / link_learned topics (push)
-module(hecate_graph_service).
-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name        => <<"hecate-graph">>,
      version     => <<"0.1.0">>,
      description => <<"Relational-graph database (CozoDB) as a mesh service">>}.

start(_Opts) ->
    hecate_graph_sup:start_link().

stop(_State) ->
    ok.

health() ->
    case hecate_graph_store:is_open() of
        true  -> ok;
        false -> {error, database_not_open}
    end.

capabilities() ->
    [#{name    => <<"hecate_graph.resolve_link">>,
       version => 1,
       handler => {resolve_link, []}},
     #{name    => <<"hecate_graph.resolve_entity">>,
       version => 1,
       handler => {resolve_entity, []}},
     #{name    => <<"hecate_graph.learn_link">>,
       version => 1,
       handler => {learn_link, []}}]
    ++ narrate_capabilities(application:get_env(hecate_graph, narration_enabled, true)).

narrate_capabilities(false) ->
    [];
narrate_capabilities(true) ->
    [#{name    => <<"hecate_graph.narrate_entity">>,
       version => 1,
       handler => {narrate_entity, []}},
     #{name    => <<"hecate_graph.narrate_link">>,
       version => 1,
       handler => {narrate_link, []}}].

identity_spec() ->
    #{scope     => <<"graph">>,
      actions   => [<<"resolve">>, <<"learn">>, <<"narrate">>],
      resources => [<<"entity_learned">>, <<"link_learned">>],
      ttl_days  => 30}.
