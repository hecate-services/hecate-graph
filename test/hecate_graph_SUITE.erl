%%% @doc Unit tests for hecate_graph.
%%%
%%% Uses meck to mock hecate_graph_store (CozoDB NIF layer) so tests run
%%% without the Rust toolchain. Tests verify business logic:
%%%   - learn_link creates entities implicitly and publishes facts
%%%   - resolve_link queries the store correctly
%%%   - resolve_entity returns entity attributes + link summary
%%%   - Error paths (missing fields, store failures)
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
    resolve_link_invalid_direction/1,
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
     resolve_link_invalid_direction,
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
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>
    }),

    ?assertEqual(2, maps:get(entities_new, Result)),
    ?assert(maps:is_key(link_id, Result)),

    verify_entity_checked(<<"did:macula:alice">>),
    verify_entity_checked(<<"did:macula:bob">>).

%% learn_link with an existing entity doesn't create it again
learn_link_reuses_existing_entity(_Config) ->
    mock_store_entity_exists_one(<<"did:macula:alice">>),
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>
    }),

    ?assertEqual(1, maps:get(entities_new, Result)).

learn_link_missing_subject(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>
    }).

learn_link_missing_predicate(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"object">> => <<"did:macula:bob">>
    }).

learn_link_missing_object(_Config) ->
    {error, missing_required_fields} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>
    }).

%% learn_link publishes link_learned fact
learn_link_publishes_link_learned(_Config) ->
    mock_store_entity_exists(0),
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"authored">>,
        <<"object">> => <<"did:macula:bob">>
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
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>
    }),

    timer:sleep(50),
    EntityFacts = collect_facts(Published, entity_learned),
    ?assertEqual(1, length(EntityFacts)),
    [EntityFact | _] = EntityFacts,
    ?assertEqual(<<"did:macula:bob">>, maps:get(entity_id, EntityFact)).

learn_link_with_metadata(_Config) ->
    mock_store_entity_exists(0),
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    mock_facts_no_publish(),

    {ok, _} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>,
        <<"metadata">> => #{<<"context">> => <<"introduction">>}
    }),

    verify_upsert_called(<<"did:macula:alice">>),
    verify_upsert_called(<<"did:macula:bob">>).

learn_link_with_confidence(_Config) ->
    mock_store_entity_exists(0),
    mock_store_upsert_ok(),
    mock_store_insert_link_ok(),
    Published = mock_facts_collect_publish(),

    learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>,
        <<"confidence">> => 0.85
    }),

    timer:sleep(50),
    LinkFacts = collect_facts(Published, link_learned),
    ?assert(length(LinkFacts) >= 1),
    [LinkFact | _] = LinkFacts,
    ?assertEqual(0.85, maps:get(confidence, LinkFact)).

learn_link_store_error(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) -> {error, database_closed} end),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"object">> => <<"did:macula:bob">>
    }),

    %% learn_link doesn't crash on store error — it logs and continues
    ?assert(maps:is_key(link_id, Result)).

%%====================================================================
%% resolve_link tests
%%====================================================================

resolve_link_direct_out(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[<<"knows">>, <<"did:macula:bob">>, 1.0, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"direction">> => <<"out">>
    }),

    ?assert(length(Rows) >= 1).

resolve_link_direct_out_with_predicate(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[<<"did:macula:bob">>, 0.9, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"predicate">> => <<"knows">>,
        <<"direction">> => <<"out">>
    }),

    ?assert(length(Rows) >= 1).

resolve_link_direct_in(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[<<"did:macula:charlie">>, <<"authored">>, 0.8, <<"hecate-graph">>, 1788244318000]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"direction">> => <<"in">>
    }),

    ?assert(length(Rows) >= 1).

resolve_link_direct_both(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[<<"out">>, <<"did:macula:bob">>, <<"knows">>, 1.0],
                               [<<"in">>, <<"did:macula:charlie">>, <<"authored">>, 0.8]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"direction">> => <<"both">>
    }),

    ?assertEqual(2, length(Rows)).

resolve_link_traverse(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[<<"did:macula:bob">>, 1],
                               [<<"did:macula:charlie">>, 2]]}}
    end),

    {ok, Rows} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"depth">> => 3
    }),

    ?assertEqual(2, length(Rows)).

resolve_link_invalid_direction(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => []}}
    end),

    {error, invalid_direction} = resolve_link:resolve(#{
        <<"subject">> => <<"did:macula:alice">>,
        <<"direction">> => <<"sideways">>
    }).

resolve_link_missing_subject(_Config) ->
    {error, missing_subject} = resolve_link:resolve(#{<<"direction">> => <<"out">>}).

%%====================================================================
%% resolve_entity tests
%%====================================================================

resolve_entity_found(_Config) ->
    meck:expect(hecate_graph_store, run, fun
        (Query, _Params) ->
            case binary:match(Query, <<"entities">>) of
                nomatch ->
                    %% link summary query
                    {ok, #{<<"rows">> => [[3, 2, [<<"knows">>, <<"authored">>]]]}};
                _ ->
                    %% entity query
                    {ok, #{<<"rows">> => [[<<"did:macula:alice">>, #{<<"name">> => <<"Alice">>}, 1788244318000, <<"hecate-graph">>]]}}
            end
    end),

    {ok, Entity} = resolve_entity:resolve(#{<<"entity_id">> => <<"did:macula:alice">>}),

    ?assertEqual(<<"did:macula:alice">>, maps:get(id, Entity)),
    ?assertEqual(3, maps:get(out_degree, Entity)),
    ?assertEqual(2, maps:get(in_degree, Entity)).

resolve_entity_not_found(_Config) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => []}}
    end),

    {error, entity_not_found} = resolve_entity:resolve(#{<<"entity_id">> => <<"did:macula:nobody">>}).

resolve_entity_missing_id(_Config) ->
    {error, missing_entity_id} = resolve_entity:resolve(#{}).

%%====================================================================
%% Mock helpers
%%====================================================================

%% Store: entity_exists returns false for all entities (count = 0)
mock_store_entity_exists(_Count) ->
    meck:expect(hecate_graph_store, run, fun(_Query, _Params) ->
        {ok, #{<<"rows">> => [[0]]}}
    end).

%% Store: entity_exists returns true for one specific entity
mock_store_entity_exists_one(ExistingId) ->
    meck:expect(hecate_graph_store, run, fun
        (_Query, #{<<"entity_id">> := ExistingId}) ->
            {ok, #{<<"rows">> => [[1]]}};
        (_Query, _Params) ->
            {ok, #{<<"rows">> => [[0]]}}
    end).

mock_store_upsert_ok() ->
    %% upsert is also a run call, so it's covered by the generic expect above.
    %% We just need to not let it crash.
    ok.

mock_store_insert_link_ok() ->
    ok.

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

verify_entity_checked(EntityId) ->
    [_, {_, Params} | _] = meck:history(hecate_graph_store),
    CheckQuery = hd([Q || {Q, _} <- meck:history(hecate_graph_store)]),
    ?assert(binary:match(CheckQuery, <<"entities">>) =/= nomatch orelse
            binary:match(CheckQuery, <<"links">>) =/= nomatch),
    %% At least one call should have used this entity_id
    History = meck:history(hecate_graph_store),
    Found = lists:any(fun({_, P}) -> maps:get(<<"entity_id">>, P, undefined) =:= EntityId end, History),
    ?assert(Found).

verify_upsert_called(_EntityId) ->
    History = meck:history(hecate_graph_store),
    UpsertCalls = [Q || {Q, _} <- History, binary:match(Q, <<":put entities">>) =/= nomatch],
    ?assert(length(UpsertCalls) >= 2).
