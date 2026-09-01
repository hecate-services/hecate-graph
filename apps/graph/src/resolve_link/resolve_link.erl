%%% @doc resolve_link: query links between entities.
%%%
%%% Supports:
%%%   - Direct links: subject → object (all predicates)
%%%   - Filtered by predicate: subject --predicate--> object
%%%   - N-hop traversal: subject → ... → object (recursive Datalog)
%%%   - Reverse: what links TO this entity?
%%%
%%% Called via mesh_call(hecate_graph.resolve_link, #{subject, ...}).
-module(resolve_link).

-export([resolve/1]).

-spec resolve(map()) -> {ok, [map()]} | {error, term()}.
resolve(#{<<"subject">> := Subject} = Params) ->
    Predicate = maps:get(<<"predicate">>, Params, undefined),
    Depth = maps:get(<<"depth">>, Params, 1),
    Direction = maps:get(<<"direction">>, Params, <<"out">>),

    case Depth of
        1 -> resolve_direct(Subject, Predicate, Direction);
        N when N > 1 -> resolve_traverse(Subject, Predicate, N, Direction)
    end;
resolve(_Params) ->
    {error, missing_subject}.

%%====================================================================
%% Internal
%%====================================================================

resolve_direct(Subject, undefined, <<"out">>) ->
    Query = <<"
        ?[predicate, object, confidence, source, learned_at] :=
            *links{subject: $subject, predicate, object, confidence, source, learned_at}
    ">>,
    run_query(Query, #{<<"subject">> => Subject});

resolve_direct(Subject, Predicate, <<"out">>) when is_binary(Predicate) ->
    Query = <<"
        ?[object, confidence, source, learned_at] :=
            *links{subject: $subject, predicate: $predicate, object, confidence, source, learned_at}
    ">>,
    run_query(Query, #{<<"subject">> => Subject, <<"predicate">> => Predicate});

resolve_direct(Subject, undefined, <<"in">>) ->
    Query = <<"
        ?[subject, predicate, confidence, source, learned_at] :=
            *links{object: $subject, subject, predicate, confidence, source, learned_at}
    ">>,
    run_query(Query, #{<<"subject">> => Subject});

resolve_direct(Subject, Predicate, <<"in">>) when is_binary(Predicate) ->
    Query = <<"
        ?[subject, confidence, source, learned_at] :=
            *links{object: $subject, predicate: $predicate, subject, confidence, source, learned_at}
    ">>,
    run_query(Query, #{<<"subject">> => Subject, <<"predicate">> => Predicate});

resolve_direct(Subject, undefined, <<"both">>) ->
    Query = <<"
        ?[direction, entity, predicate, confidence] :=
            *links{subject: $subject, predicate, object, confidence, source, learned_at},
            entity = object, direction = 'out'
        ?[direction, entity, predicate, confidence] :=
            *links{object: $subject, subject, predicate, confidence, source, learned_at},
            entity = subject, direction = 'in'
    ">>,
    run_query(Query, #{<<"subject">> => Subject});

resolve_direct(_, _, _) ->
    {error, invalid_direction}.

resolve_traverse(Subject, Predicate, Depth, _Direction) ->
    PredFilter = case Predicate of
        undefined -> <<"">>;
        _Pred -> <<", predicate: $predicate">>
    end,
    Params0 = #{<<"subject">> => Subject},
    Params = case Predicate of
        undefined -> Params0;
        Pred -> Params0#{<<"predicate">> => Pred}
    end,

    %% Recursive Datalog: reachable entities within N hops.
    Query = <<
        "reachable[entity, hop] := *links{subject: $subject, object: entity", PredFilter/binary, "}, hop = 1\n"
        "reachable[entity, hop] := reachable[prev, prev_hop],\n"
        "  *links{subject: prev, object: entity", PredFilter/binary, "},\n"
        "  hop = prev_hop + 1, hop <= ", (integer_to_binary(Depth))/binary, "\n"
        "?[entity, hop] := reachable[entity, hop], entity != $subject\n"
        ":order hop, entity"
    >>,
    run_query(Query, Params).

run_query(Query, Params) ->
    case hecate_graph_store:run(Query, Params) of
        {ok, #{<<"rows">> := Rows}} ->
            {ok, rows_to_maps(Rows)};
        {ok, Result} when is_map(Result) ->
            {ok, maps:get(<<"rows">>, Result, [])};
        {error, Reason} = Error ->
            logger:warning("resolve_link query failed: ~p", [Reason]),
            Error
    end.

rows_to_maps(Rows) ->
    [row_to_map(Row) || Row <- Rows].

row_to_map(Row) when is_list(Row) ->
    %% CozoDB returns rows as lists of values in column order.
    %% The caller knows the order from the query; we return a list.
    %% For convenience, if the row has named headers we could map them,
    %% but CozoDB's JSON response includes headers separately.
    {row, Row}.
