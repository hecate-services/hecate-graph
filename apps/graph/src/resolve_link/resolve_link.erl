%%% @doc resolve_link: query links between entities.
%%%
%%% Supports:
%%%   - Direct links: subject → object (all predicates)
%%%   - Filtered by predicate: subject --predicate--> object
%%%   - N-hop traversal: subject → ... → object (recursive Datalog),
%%%     honoring direction the same way direct lookups do
%%%   - Reverse: what links TO this entity?
%%%
%%% Registered as this service's `hecate_graph.resolve_link' mesh
%%% procedure via `hecate_om_capabilities' (see
%%% hecate_graph_service:capabilities/0).
-module(resolve_link).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([resolve/1]).

%%====================================================================
%% macula_response
%%====================================================================

init(_Args) -> {ok, undefined}.

handle_request(Payload, State) ->
    case resolve(Payload) of
        {ok, Result} -> {reply, #{rows => Result}, State};
        {error, Reason} -> {error, Reason, State}
    end.

%%====================================================================
%% API
%%====================================================================

%% RPC payloads decode ATOM-keyed (macula_response's contract) -- but
%% read via hecate_om_wire:field/2,3, never a hard #{key := V} match in
%% the head. Corpus Demon 60: a hard match on the wrong key shape falls
%% through silently to the catch-all instead of erroring loudly.
-spec resolve(map()) -> {ok, [map()]} | {error, term()}.
resolve(Params) when is_map(Params) ->
    resolve_(hecate_om_wire:field(subject, Params), Params);
resolve(_Params) ->
    {error, missing_subject}.

resolve_(undefined, _Params) -> {error, missing_subject};
resolve_(Subject, Params) ->
    Predicate = hecate_om_wire:field(predicate, Params),
    Depth = hecate_om_wire:field(depth, Params, 1),
    Direction = hecate_om_wire:field(direction, Params, <<"out">>),
    dispatch(Subject, Predicate, Depth, Direction).

dispatch(Subject, Predicate, 1, Direction) ->
    resolve_direct(Subject, Predicate, Direction);
dispatch(Subject, Predicate, Depth, Direction) when is_integer(Depth), Depth > 1 ->
    resolve_traverse(Subject, Predicate, Depth, Direction);
dispatch(_Subject, _Predicate, _Depth, _Direction) ->
    {error, invalid_depth}.

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

%% Direction-aware N-hop traversal. `out' walks subject->object edges
%% forward, `in' walks object->subject edges backward (what reaches
%% `Subject'), `both' unions the two starting steps and continues forward
%% from either. Previously this ignored Direction outright and always
%% walked forward, so `direction => <<"in">>' silently returned the wrong
%% answer instead of an error.
resolve_traverse(_Subject, _Predicate, _Depth, Direction)
  when Direction =/= <<"out">>, Direction =/= <<"in">>, Direction =/= <<"both">> ->
    {error, invalid_direction};
resolve_traverse(Subject, Predicate, Depth, Direction) ->
    PredFilter = pred_filter(Predicate),
    Params = traverse_params(Subject, Predicate),
    Query = traverse_query(Direction, PredFilter, Depth),
    run_query(Query, Params).

pred_filter(undefined) -> <<"">>;
pred_filter(_Pred) -> <<", predicate: $predicate">>.

traverse_params(Subject, undefined) ->
    #{<<"subject">> => Subject};
traverse_params(Subject, Predicate) ->
    #{<<"subject">> => Subject, <<"predicate">> => Predicate}.

traverse_query(<<"out">>, PredFilter, Depth) ->
    <<
        (seed_rule(<<"subject: $subject">>, PredFilter))/binary,
        (step_rule(<<"subject: prev">>, PredFilter, Depth))/binary,
        (result_rule())/binary
    >>;
traverse_query(<<"in">>, PredFilter, Depth) ->
    <<
        (seed_rule(<<"object: $subject">>, PredFilter))/binary,
        (step_rule(<<"object: prev">>, PredFilter, Depth))/binary,
        (result_rule())/binary
    >>;
traverse_query(<<"both">>, PredFilter, Depth) ->
    <<
        (seed_rule(<<"subject: $subject">>, PredFilter))/binary,
        (seed_rule(<<"object: $subject">>, PredFilter))/binary,
        (step_rule(<<"subject: prev">>, PredFilter, Depth))/binary,
        (step_rule(<<"object: prev">>, PredFilter, Depth))/binary,
        (result_rule())/binary
    >>.

%% The first hop: entities directly linked to $subject via `Anchor'
%% (`subject: $subject' for an outgoing edge, `object: $subject' for an
%% incoming one). `entity' is always the OTHER end of the link.
seed_rule(Anchor, PredFilter) ->
    Entity = other_end(Anchor),
    <<"reachable[entity, hop] := *links{", Anchor/binary, ", ", Entity/binary,
      ": entity", PredFilter/binary, "}, hop = 1\n">>.

%% Subsequent hops: continue from whichever entity the previous hop
%% reached (`prev'), same anchor/other-end shape, capped at Depth.
step_rule(Anchor, PredFilter, Depth) ->
    Entity = other_end(Anchor),
    <<"reachable[entity, hop] := reachable[prev, prev_hop],\n"
      "  *links{", Anchor/binary, ", ", Entity/binary, ": entity", PredFilter/binary, "},\n"
      "  hop = prev_hop + 1, hop <= ", (integer_to_binary(Depth))/binary, "\n">>.

other_end(<<"subject: prev">>) -> <<"object">>;
other_end(<<"object: prev">>) -> <<"subject">>;
other_end(<<"subject: $subject">>) -> <<"object">>;
other_end(<<"object: $subject">>) -> <<"subject">>.

result_rule() ->
    <<"?[entity, hop] := reachable[entity, hop], entity != $subject\n"
      ":order hop, entity">>.

run_query(Query, Params) ->
    case hecate_graph_store:run(Query, Params) of
        {ok, #{<<"headers">> := Headers, <<"rows">> := Rows}} ->
            {ok, rows_to_maps(Headers, Rows)};
        {ok, #{<<"rows">> := Rows}} ->
            {ok, Rows};
        {error, Reason} = Error ->
            logger:warning("resolve_link query failed: ~p", [Reason]),
            Error
    end.

rows_to_maps(Headers, Rows) ->
    [row_to_map(Headers, Row) || Row <- Rows].

%% CozoDB returns each row as a positional list in column order, with the
%% column names in `headers' (see the NIF's `NamedRows'-derived JSON).
%% Zipped into a map so a mesh caller gets named fields, matching this
%% module's own `-spec ... {ok, [map()]}' — previously this returned a
%% bare `{row, Row}' tuple that matched neither the spec nor any decoder
%% downstream expected of it.
row_to_map(Headers, Row) when length(Headers) =:= length(Row) ->
    maps:from_list(lists:zip(Headers, Row));
row_to_map(_Headers, Row) ->
    %% Header/row arity mismatch — fall back to the raw row rather than
    %% crash zipping mismatched lists.
    Row.
