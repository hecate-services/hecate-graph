%%% @doc resolve_entity: query entity attributes and links.
%%%
%%% Returns an entity's stored attributes plus a summary of its links
%%% (out-degree, in-degree, predicates). For full link traversal, use
%%% resolve_link with a depth parameter.
%%%
%%% Called via mesh_call(hecate_graph.resolve_entity, #{entity_id, ...}).
-module(resolve_entity).

-export([resolve/1]).

-spec resolve(map()) -> {ok, map()} | {error, term()}.
resolve(#{<<"entity_id">> := EntityId}) ->
    case get_entity(EntityId) of
        {ok, Entity} ->
            case get_link_summary(EntityId) of
                {ok, Summary} ->
                    {ok, maps:merge(Entity, Summary)};
                {error, _} ->
                    {ok, Entity}
            end;
        {error, not_found} ->
            {error, entity_not_found}
    end;
resolve(_Params) ->
    {error, missing_entity_id}.

%%====================================================================
%% Internal
%%====================================================================

get_entity(EntityId) ->
    Query = <<"
        ?[id, attributes, first_seen, source] :=
            *entities{id: $entity_id, id, attributes, first_seen, source}
    ">>,
    case hecate_graph_store:run(Query, #{<<"entity_id">> => EntityId}) of
        {ok, #{<<"rows">> := [[Id, Attrs, FirstSeen, Source] | _]}} ->
            {ok, #{id => Id,
                   attributes => Attrs,
                   first_seen => FirstSeen,
                   source => Source}};
        {ok, #{<<"rows">> := []}} ->
            {error, not_found};
        {error, Reason} ->
            logger:warning("resolve_entity query failed: ~p", [Reason]),
            {error, Reason}
    end.

get_link_summary(EntityId) ->
    Query = <<"
        out_count[count(n)] := *links{subject: $entity_id, n}
        in_count[count(n)] := *links{object: $entity_id, n}
        predicates_out[.predicate] := *links{subject: $entity_id, predicate}
        ?[out_degree, in_degree, predicates_out] :=
            out_count[out_degree],
            in_count[in_degree]
    ">>,
    case hecate_graph_store:run(Query, #{<<"entity_id">> => EntityId}) of
        {ok, #{<<"rows">> := [[OutDeg, InDeg, Preds] | _]}} ->
            {ok, #{out_degree => OutDeg,
                   in_degree => InDeg,
                   predicates => Preds}};
        {error, _} = Error ->
            Error
    end.
