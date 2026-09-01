%%% @doc Unit tests for hecate_graph.
%%%
%%% Uses meck to mock hecate_graph_store (CozoDB NIF layer) so tests run
%%% without the Rust toolchain. Tests verify business logic:
%%%   - learn_link creates entities implicitly (atomically, via CozoDB's
%%%     `:insert`) and publishes facts
%%%   - resolve_link queries the store correctly, including direction-aware
%%%     traversal and named-map row shaping
%%%   - resolve_entity returns entity attributes + link summary
%%%   - Error paths (missing fields, store failures, invalid depth)
%%%
%%% RPC payloads (the maps passed to learn_link:learn/1,
%%% resolve_link:resolve/1, resolve_entity:resolve/1) are ATOM-keyed here,
%%% matching macula_response's real decode contract — NOT the binary-keyed
%%% shape a plain JSON HTTP body would decode to. Params passed on to
%%% hecate_graph_store:run/2 (Cozo query variable bindings) stay
%%% binary-keyed regardless, since those are Datalog variable names, not
%%% RPC fields.
-module(hecate_graph_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    %% learn_link
    learn_link_creates_both/1,
    learn_link_reuses_existing_entity/1,
    learn_link_missing_subject/1,
    learn_link_missing_predicate/1,
    learn_link_missing_object/1,
    learn_link_publishes_link_learned/1,
    learn_link_publishes_entity_learned_for_new_only/1,
    learn_link_with_metadata/1,
    learn_link_with_confidence/1,
    learn_link_store_error/1,
    %% resolve_link
    resolve_link_direct_out/1,
    resolve_link_direct_out_with_predicate/1,
    resolve_link_direct_in/1,
    resolve_link_direct_both/1,
    resolve_link_traverse/1,
    resolve_link_traverse_in_direction/1,
    resolve_link_invalid_direction/1,
    resolve_link_invalid_depth/1,
    resolve_link_missing_subject/1,
    %% resolve_entity
    resolve_entity_found/1,
    resolve_entity_not_found/1,
    resolve_entity_missing_id/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
     learn_link_creates_both,
     learn_link_reuses_existing_entity,
     learn_link_missing_subject,
     learn_link_missing_predicate,
     learn_link_missing_object,
     learn_link_publishes_link_learned,
     learn_link_publishes_entity_learned_for_new_only,
     learn_link_with_metadata,
     learn_link_with_confidence,
     learn_link_store_error,
     resolve_link_direct_out,
     resolve_link_direct_out_with_predicate,
     resolve_link_direct_in,
     resolve_link_direct_both,
     resolve_link_traverse,
     resolve_link_traverse_in_direction,
     resolve_link_invalid_direction,
     resolve_link_invalid_depth,
     resolve_link_missing_subject,
     resolve_entity_found,
     resolve_entity_not_found,
     resolve_entity_missing_id
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(crypto),
    application:load(hecate_graph),
    Config.

end_per_suite(_Config) ->
    application:unload(hecate_graph),
    ok.

init_per_testcase(_TestCase, Config) ->
    meck:new(hecate_graph_store, [non_strict]),
    meck:new(hecate_graph_facts, [non_strict, passthrough]),
    Config.

end_per_testcase(_TestCase, _Config) ->
    meck:unload(hecate_graph_store),
    meck:unload(hecate_graph_facts),
    ok.

%%====================================================================
%% learn_link tests
%%====================================================================

%% learn_link with two new entities creates both
learn_link_creates_both(_Config) ->
    mock_store_entity_exists(0),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }),

    ?assertEqual(2, maps:get(entities_new, Result)),
    ?assert(maps:is_key(link_id, Result)),

    verify_entity_checked(<<"did:macula:alice">>),
    verify_entity_checked(<<"did:macula:bob">>).

%% learn_link with an existing entity doesn't create it again
learn_link_reuses_existing_entity(_Config) ->
    mock_store_entity_exists_one(<<"did:macula:alice">>),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }),

    ?assertEqual(1, maps:get(entities_new, Result)).

learn_link_missing_subject(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }).

learn_link_missing_predicate(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        object => <<"did:macula:bob">>
    }).

learn_link_missing_object(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>
    }).

%% learn_link publishes link_learned fact
learn_link_publishes_link_learned(_Config) ->
    mock_store_entity_exists(0),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"authored">>,
        object => <<"did:macula:bob">>
    }),

    timer:sleep(50),
    LinkFacts = collect_facts(Published, link_learned),
    ?assert(length(LinkFacts) >= 1),
    [LinkFact | _] = LinkFacts,
    ?assertEqual(<<"did:macula:alice">>, maps:get(subject, LinkFact)),
    ?assertEqual(<<"authored">>, maps:get(predicate, LinkFact)),
    ?assertEqual(<<"did:macula:bob">>, maps:get(object, LinkFact)).

%% learn_link publishes entity_learned only for new entities
learn_link_publishes_entity_learned_for_new_only(_Config) ->
    mock_store_entity_exists_one(<<"did:macula:alice">>),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }),

    timer:sleep(50),
    EntityFacts = collect_facts(Published, entity_learned),
    ?assertEqual(1, length(EntityFacts)),
    [EntityFact | _] = EntityFacts,
    ?assertEqual(<<"did:macula:bob">>, maps:get(entity_id, EntityFact)).

learn_link_with_metadata(_Config) ->
    mock_store_entity_exists(0),
    mock_facts_no_publish(),

    {ok, _} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>,
        metadata => #{<<"context">> => <<"introduction">>}
    }),

    verify_upsert_called(<<"did:macula:alice">>),
    verify_upsert_called(<<"did:macula:bob">>).

learn_link_with_confidence(_Config) ->
    mock_store_entity_exists(0),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>,
        confidence => 0.85
    }),

    timer:sleep(50),
    LinkFacts = collect_facts(Published, link_learned),
    ?assert(length(LinkFacts) >= 1),
    [LinkFact | _] = LinkFacts,
    ?assertEqual(0.85, maps:get(confidence, LinkFact)).

learn_link_store_error(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) -> {error, database_closed} end),
    mock_facts_no_publish(),

    %% A store failure now propagates as an error — it used to be logged
    %% and swallowed, reporting success to the mesh caller even though
    %% nothing was durably recorded.
    ?assertEqual({error, database_closed}, learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    })).

%%====================================================================
%% resolve_link tests
%%====================================================================

resolve_link_direct_out(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"headers">> => [<<"predicate">>, <<"object">>, <<"confidence">>, <<"source">>, <<"learned_at">>],
               <<"rows">> => [[<<"knows">>, <<"did:macula:bob">>, 1.0, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        direction => <<"out">>
    }),

    ?assertEqual(1, length(Rows)),
    [Row | _] = Rows,
    ?assertEqual(<<"knows">>, maps:get(<<"predicate">>, Row)),
    ?assertEqual(<<"did:macula:bob">>, maps:get(<<"object">>, Row)).

resolve_link_direct_out_with_predicate(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"headers">> => [<<"object">>, <<"confidence">>, <<"source">>, <<"learned_at">>],
               <<"rows">> => [[<<"did:macula:bob">>, 0.9, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        direction => <<"out">>
    }),

    ?assertEqual(1, length(Rows)),
    [Row | _] = Rows,
    ?assertEqual(<<"did:macula:bob">>, maps:get(<<"object">>, Row)).

resolve_link_direct_in(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"headers">> => [<<"subject">>, <<"predicate">>, <<"confidence">>, <<"source">>, <<"learned_at">>],
               <<"rows">> => [[<<"did:macula:charlie">>, <<"authored">>, 0.8, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        direction => <<"in">>
    }),

    ?assertEqual(1, length(Rows)),
    [Row | _] = Rows,
    ?assertEqual(<<"did:macula:charlie">>, maps:get(<<"subject">>, Row)).

resolve_link_direct_both(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"headers">> => [<<"direction">>, <<"entity">>, <<"predicate">>, <<"confidence">>],
               <<"rows">> => [[<<"out">>, <<"did:macula:bob">>, <<"knows">>, 1.0],
                               [<<"in">>, <<"did:macula:charlie">>, <<"authored">>, 0.8]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        direction => <<"both">>
    }),

    ?assertEqual(2, length(Rows)).

resolve_link_traverse(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"headers">> => [<<"entity">>, <<"hop">>],
               <<"rows">> => [[<<"did:macula:bob">>, 1],
                               [<<"did:macula:charlie">>, 2]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        depth => 3
    }),

    ?assertEqual(2, length(Rows)).

%% direction => in traversal must walk object->subject edges, not fall
%% through to the forward (subject->object) shape it silently used before
%% this was fixed — verified by inspecting the generated query text.
resolve_link_traverse_in_direction(_Config) ->
    meck:expect(hecate_graph_store, run, fun(Query, _Params) ->
        ?assert(binary:match(Query, <<"object: $subject">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(Query, <<"subject: $subject">>)),
        {ok, #{<<"headers">> => [<<"entity">>, <<"hop">>],
               <<"rows">> => [[<<"did:macula:zed">>, 1]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        depth => 2,
        direction => <<"in">>
    }),

    ?assertEqual(1, length(Rows)).

resolve_link_invalid_direction(_Config) ->
    {error, invalid_direction} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        direction => <<"sideways">>
    }).

%% depth =< 0 (or any non-positive-integer depth) is a caller error, not a
%% crash — resolve/1's dispatch used to have no clause for it at all.
resolve_link_invalid_depth(_Config) ->
    {error, invalid_depth} = resolve_link:resolve(#{
        subject => <<"did:macula:alice">>,
        depth => 0
    }).

resolve_link_missing_subject(_Config) ->
    {error, missing_subject} = resolve_link:resolve(#{direction => <<"out">>}).

%%====================================================================
%% resolve_entity tests
%%====================================================================

resolve_entity_found(_Config) ->
    meck:expect(hecate_graph_store, run, fun(Query, _Params) ->
        entity_query_result(Query)
    end),

    {ok, Entity} = resolve_entity:resolve(#{entity_id => <<"did:macula:alice">>}),

    ?assertEqual(<<"did:macula:alice">>, maps:get(id, Entity)),
    ?assertEqual(3, maps:get(out_degree, Entity)),
    ?assertEqual(2, maps:get(in_degree, Entity)),
    ?assertEqual([<<"knows">>, <<"authored">>], maps:get(predicates, Entity)).

resolve_entity_not_found(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => []}}
    end),

    {error, entity_not_found} = resolve_entity:resolve(#{entity_id => <<"did:macula:nobody">>}).

resolve_entity_missing_id(_Config) ->
    {error, missing_entity_id} = resolve_entity:resolve(#{}).

%%====================================================================
%% Mock helpers
%%====================================================================

%% Store: every entity is new — the `:insert' ensure_entity/4 issues
%% succeeds unconditionally.
mock_store_entity_exists(_Count) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[]]}}
    end).

%% Store: `ExistingId''s `:insert' fails with CozoDB's real "already
%% exist" wording (ensure_entity/4's already_exists/1 checks for that
%% substring); every other entity_id, and any other call (insert_link),
%% succeeds.
mock_store_entity_exists_one(ExistingId) ->
    meck:expect(hecate_graph_store, run, fun
        (_Query, #{<<"entity_id">> := Id}) when Id =:= ExistingId ->
            {error, <<"key 'id' already exist for entities">>};
        (_Query, _Params) ->
            {ok, #{<<"rows">> => [[]]}}
    end).

mock_facts_no_publish() ->
    meck:expect(hecate_graph_facts, publish_entity_learned, fun(_Fact) -> ok end),
    meck:expect(hecate_graph_facts, publish_link_learned, fun(_Fact) -> ok end).

mock_facts_collect_publish() ->
    Collector = spawn(fun() -> collector_loop([]) end),
    meck:expect(hecate_graph_facts, publish_entity_learned, fun(Fact) ->
        Collector ! {fact, entity_learned, Fact},
        ok
    end),
    meck:expect(hecate_graph_facts, publish_link_learned, fun(Fact) ->
        Collector ! {fact, link_learned, Fact},
        ok
    end),
    Collector.

collector_loop(Facts) ->
    receive
        {get_facts, Pid} ->
            Pid ! {facts, Facts},
            collector_loop(Facts);
        {fact, Type, Fact} ->
            collector_loop([{Type, Fact} | Facts])
    after 5000 ->
        ok
    end.

collect_facts(Collector, Type) ->
    Collector ! {get_facts, self()},
    receive
        {facts, Facts} ->
            [F || {T, F} <- Facts, T =:= Type]
    after 1000 ->
        []
    end.

%% meck:history/1 entries are `{CallerPid, {Mod, Func, Args}, Result}' —
%% NOT `{Query, Params}' pairs. Matching the wrong shape either badmatches
%% or (via a mismatched list comprehension pattern) silently produces an
%% empty list, both of which previously made these helpers unreliable.
store_run_calls() ->
    [{Query, Params}
     || {_Pid, {hecate_graph_store, run, [Query, Params]}, _Result} <- meck:history(hecate_graph_store)].

verify_entity_checked(EntityId) ->
    Calls = store_run_calls(),
    ?assert(lists:any(fun({Q, _P}) -> binary:match(Q, <<"entities">>) =/= nomatch end, Calls)),
    Found = lists:any(fun({_Q, P}) -> maps:get(<<"entity_id">>, P, undefined) =:= EntityId end, Calls),
    ?assert(Found).

verify_upsert_called(_EntityId) ->
    Calls = store_run_calls(),
    UpsertCalls = [Q || {Q, _P} <- Calls, binary:match(Q, <<":insert entities">>) =/= nomatch],
    ?assert(length(UpsertCalls) >= 2).

%% resolve_entity_found's mock: dispatch on which of the four query shapes
%% resolve_entity.erl issues (entity attributes, out-degree, in-degree,
%% predicates) by a distinctive substring of each.
entity_query_result(Query) ->
    dispatch_entity_query(
        binary:match(Query, <<"collect(p)">>),
        binary:match(Query, <<"subject: $entity_id, link_id">>),
        binary:match(Query, <<"object: $entity_id, link_id">>),
        Query).

dispatch_entity_query({_, _}, nomatch, nomatch, _Query) ->
    {ok, #{<<"rows">> => [[[<<"knows">>, <<"authored">>]]]}};
dispatch_entity_query(nomatch, {_, _}, nomatch, _Query) ->
    {ok, #{<<"rows">> => [[3]]}};
dispatch_entity_query(nomatch, nomatch, {_, _}, _Query) ->
    {ok, #{<<"rows">> => [[2]]}};
dispatch_entity_query(nomatch, nomatch, nomatch, _Query) ->
    {ok, #{<<"rows">> => [[#{<<"name">> => <<"Alice">>}, 1788244318000, <<"hecate-graph">>]]}}.
