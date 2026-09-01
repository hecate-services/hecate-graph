%%% @doc narrate_entity: prose description of an entity and its links.
%%%
%%% Phase 3 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md). Wraps resolve_entity
%%% internally as a plain Erlang function call -- no mesh round-trip,
%%% no new query logic -- and hands the result to
%%% `hecate_graph_narrator:narrate/2'. Its OWN desk, not a `format'
%%% parameter on resolve_entity: see that module's own moduledoc for
%%% why an LLM-backed call must not share a procedure with a plain
%%% Cozo query.
%%%
%%% Registered as this service's `hecate_graph.narrate_entity' mesh
%%% procedure via `hecate_om_capabilities' (see
%%% hecate_graph_service:capabilities/0), independent of
%%% `hecate_graph.resolve_entity' -- a realm operator can disable
%%% narration alone.
-module(narrate_entity).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([narrate/1]).

init(_Args) -> {ok, undefined}.

handle_request(Payload, State) ->
    case narrate(Payload) of
        {ok, Result} -> {reply, Result, State};
        {error, Reason} -> {error, Reason, State}
    end.

-spec narrate(map()) -> {ok, map()} | {error, term()}.
narrate(Params) when is_map(Params) ->
    narrate_(hecate_om_wire:field(entity_id, Params), Params);
narrate(_Params) ->
    {error, missing_entity_id}.

narrate_(undefined, _Params) ->
    {error, missing_entity_id};
narrate_(EntityId, Params) ->
    resolved(resolve_entity:resolve(#{entity_id => EntityId}), EntityId, Params).

resolved({error, _} = Error, _EntityId, _Params) ->
    Error;
resolved({ok, Entity}, EntityId, Params) ->
    Subgraph = #{type => entity, entity_id => EntityId, entity => Entity},
    {ok, Prose} = hecate_graph_narrator:narrate(Subgraph, opts(Params)),
    {ok, #{entity_id => EntityId, prose => Prose}}.

opts(Params) ->
    #{model => hecate_om_wire:field(model, Params)}.
