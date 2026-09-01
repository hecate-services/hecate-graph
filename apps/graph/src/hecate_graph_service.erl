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
       handler => {learn_link, []}}].

identity_spec() ->
    #{scope     => <<"graph">>,
      actions   => [<<"resolve">>, <<"learn">>],
      resources => [<<"entity_learned">>, <<"link_learned">>],
      ttl_days  => 30}.
