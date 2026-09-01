%%% @doc resolve_entity: query entity attributes and links.
%%%
%%% Returns an entity's stored attributes plus a summary of its links
%%% (out-degree, in-degree, predicates). For full link traversal, use
%%% resolve_link with a depth parameter.
%%%
%%% Registered as this service's `hecate_graph.resolve_entity` mesh
%%% procedure via `hecate_om_capabilities` (see
%%% hecate_graph_service:capabilities/0).
-module(resolve_entity).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([resolve/1]).

%%====================================================================
%% macula_response
%%====================================================================

init(_Args) -> {ok, undefined}.

handle_request(Payload, State) ->
    case resolve(Payload) of
        {ok, Result} -> {reply, Result, State};
        {error, Reason} -> {error, Reason, State}
    end.

%%====================================================================
%% API
%%====================================================================

%% RPC payloads decode ATOM-keyed (macula_response's contract) -- but
%% read via hecate_om_wire:field/2,3, never a hard #{key := V} match in
%% the head. Corpus Demon 60: a hard match on the wrong key shape falls
%% through silently to the catch-all instead of erroring loudly.
-spec resolve(map()) -> {ok, map()} | {error, term()}.
resolve(Params) when is_map(Params) ->
    resolve_(hecate_om_wire:field(entity_id, Params));
resolve(_Params) ->
    {error, missing_entity_id}.

resolve_(undefined) -> {error, missing_entity_id};
resolve_(EntityId) ->
    case get_entity(EntityId) of
        {ok, Entity} -> merge_link_summary(Entity, EntityId);
        {error, not_found} -> {error, entity_not_found}
    end.

merge_link_summary(Entity, EntityId) ->
    case get_link_summary(EntityId) of
        {ok, Summary} -> {ok, maps:merge(Entity, Summary)};
        {error, _} -> {ok, Entity}
    end.

%%====================================================================
%% Internal
%%====================================================================

get_entity(EntityId) ->
    %% `id' is bound only via the `id: $entity_id' filter — EntityId is
    %% already known to the caller, so the row only needs to carry the
    %% value columns, avoiding a double-binding of `id' in one atom.
    Query = <<"
        ?[attributes, first_seen, source] :=
            *entities{id: $entity_id, attributes, first_seen, source}
    ">>,
    case hecate_graph_store:run(Query, #{<<"entity_id">> => EntityId}) of
        {ok, #{<<"rows">> := [[Attrs, FirstSeen, Source] | _]}} ->
            {ok, #{id => EntityId,
                   attributes => Attrs,
                   first_seen => FirstSeen,
                   source => Source}};
        {ok, #{<<"rows">> := []}} ->
            {error, not_found};
        {error, Reason} ->
            logger:warning("resolve_entity query failed: ~p", [Reason]),
            {error, Reason}
    end.

%% Three independent single-aggregate queries rather than one 3-way join
%% across named sub-rules: a lone `?[count(x)] := body' (no group-by
%% variable) reliably yields exactly one row — 0 when body matches
%% nothing — but joining several such sub-rules together is only
%% guaranteed to yield a row when ALL of them independently matched,
%% which an entity with (say) outgoing but no incoming links would fail.
%% Three round trips instead of one, in exchange for not depending on
%% that edge case. Counts via `link_id' — the links relation's actual
%% primary key, always present and unique per row (the schema has no
%% column literally named `n', which is what made the original single
%% query here error on every call).
get_link_summary(EntityId) ->
    case out_degree(EntityId) of
        {error, _} = Error -> Error;
        {ok, OutDeg} -> with_in_degree(EntityId, OutDeg)
    end.

with_in_degree(EntityId, OutDeg) ->
    case in_degree(EntityId) of
        {error, _} = Error -> Error;
        {ok, InDeg} -> with_predicates(EntityId, OutDeg, InDeg)
    end.

with_predicates(EntityId, OutDeg, InDeg) ->
    case predicates_out(EntityId) of
        {error, _} = Error -> Error;
        {ok, Preds} -> {ok, #{out_degree => OutDeg, in_degree => InDeg, predicates => Preds}}
    end.

out_degree(EntityId) ->
    Query = <<"?[n] := n = count(l), *links{subject: $entity_id, link_id: l}">>,
    run_scalar(Query, EntityId).

in_degree(EntityId) ->
    Query = <<"?[n] := n = count(l), *links{object: $entity_id, link_id: l}">>,
    run_scalar(Query, EntityId).

predicates_out(EntityId) ->
    Query = <<"?[preds] := preds = collect(p), *links{subject: $entity_id, predicate: p}">>,
    run_scalar(Query, EntityId).

run_scalar(Query, EntityId) ->
    case hecate_graph_store:run(Query, #{<<"entity_id">> => EntityId}) of
        {ok, #{<<"rows">> := [[Value] | _]}} -> {ok, Value};
        {error, Reason} -> {error, Reason}
    end.
