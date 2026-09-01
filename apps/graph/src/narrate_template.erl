%%% @doc Deterministic prose fallback: sentence-per-triple templating,
%%% no LLM, no network call, cannot fail. This is the backstop
%%% `hecate_graph_narrator' falls through to when the configured LLM
%%% backend errors, crashes, or the mesh is dark -- so its own contract
%%% is stricter than `hecate_graph_narrator''s -callback: always
%%% `{ok, binary()}', never `{error, _}'.
-module(narrate_template).
-behaviour(hecate_graph_narrator).

-export([narrate/2]).

-spec narrate(map(), map()) -> {ok, binary()}.
narrate(#{type := entity, entity_id := EntityId, entity := Entity}, _Opts) ->
    {ok, entity_sentence(EntityId, Entity)};
narrate(#{type := links, subject := Subject, links := Links}, _Opts) ->
    {ok, links_sentence(Subject, Links)};
narrate(_Subgraph, _Opts) ->
    {ok, <<"No data available to describe.">>}.

entity_sentence(EntityId, Entity) ->
    OutDeg = maps:get(out_degree, Entity, 0),
    InDeg = maps:get(in_degree, Entity, 0),
    Predicates = maps:get(predicates, Entity, []),
    iolist_to_binary([
        EntityId, <<" has ">>, integer_to_binary(OutDeg), <<" outgoing and ">>,
        integer_to_binary(InDeg), <<" incoming link(s)">>,
        predicates_clause(Predicates), <<".">>
    ]).

predicates_clause([]) ->
    <<>>;
predicates_clause(Predicates) ->
    [<<", via: ">>, lists:join(<<", ">>, Predicates)].

links_sentence(_Subject, []) ->
    <<"No links found.">>;
links_sentence(Subject, Links) ->
    iolist_to_binary(lists:join(<<" ">>, [triple_sentence(Subject, L) || L <- Links])).

triple_sentence(Subject, #{predicate := Predicate, object := Object}) ->
    [Subject, <<" ">>, Predicate, <<" ">>, Object, <<".">>].
