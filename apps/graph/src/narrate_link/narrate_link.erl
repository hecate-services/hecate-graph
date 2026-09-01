%%% @doc narrate_link: prose description of a subject's links.
%%%
%%% Phase 3 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md). Wraps resolve_link
%%% internally as a plain Erlang function call -- no mesh round-trip,
%%% no new query logic -- and hands the result to
%%% `hecate_graph_narrator:narrate/2'. See narrate_entity's own
%%% moduledoc for why this is a separate desk, not a `format' parameter
%%% on resolve_link.
%%%
%%% Registered as this service's `hecate_graph.narrate_link' mesh
%%% procedure via `hecate_om_capabilities' (see
%%% hecate_graph_service:capabilities/0), independent of
%%% `hecate_graph.resolve_link' -- a realm operator can disable
%%% narration alone.
-module(narrate_link).

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
    narrate_(hecate_om_wire:field(subject, Params), Params);
narrate(_Params) ->
    {error, missing_subject}.

narrate_(undefined, _Params) ->
    {error, missing_subject};
narrate_(Subject, Params) ->
    resolved(resolve_link:resolve(Params), Subject, Params).

resolved({error, _} = Error, _Subject, _Params) ->
    Error;
resolved({ok, Links}, Subject, Params) ->
    Subgraph = #{type => links, subject => Subject, links => Links},
    {ok, Prose} = hecate_graph_narrator:narrate(Subgraph, opts(Params)),
    {ok, #{subject => Subject, prose => Prose}}.

opts(Params) ->
    #{model => hecate_om_wire:field(model, Params)}.
