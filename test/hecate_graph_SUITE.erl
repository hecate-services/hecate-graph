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
    learn_link_handles_real_wire_shaped_values/1,
    learn_link_records_caller_provenance/1,
    learn_link_no_provenance_without_caller/1,
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
    resolve_entity_missing_id/1,
    %% learn_truths_from_mesh
    truths_verified_publisher_gets_confidence_07/1,
    truths_unsigned_publisher_gets_confidence_04/1,
    truths_missing_publisher_verified_key_degrades_gracefully/1,
    truths_invalid_signature_rejected/1,
    truths_learn_link_error_does_not_crash/1,
    %% narrate_entity / narrate_link / hecate_graph_narrator
    narrate_entity_returns_prose/1,
    narrate_entity_missing_entity_id/1,
    narrate_entity_propagates_resolve_error/1,
    narrate_link_returns_prose/1,
    narrate_link_missing_subject/1,
    narrator_falls_back_to_template_on_backend_error/1,
    narrator_falls_back_to_template_on_backend_crash/1,
    narrate_template_entity_sentence/1,
    narrate_template_links_sentence/1,
    narrate_template_no_links/1,
    narrate_hecate_llm_calls_hecate_llm_chat/1,
    narrate_hecate_llm_uses_opts_model_override/1,
    narrate_hecate_llm_dark_mesh_returns_error/1
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
     learn_link_handles_real_wire_shaped_values,
     learn_link_records_caller_provenance,
     learn_link_no_provenance_without_caller,
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
     resolve_entity_missing_id,
     truths_verified_publisher_gets_confidence_07,
     truths_unsigned_publisher_gets_confidence_04,
     truths_missing_publisher_verified_key_degrades_gracefully,
     truths_invalid_signature_rejected,
     truths_learn_link_error_does_not_crash,
     narrate_entity_returns_prose,
     narrate_entity_missing_entity_id,
     narrate_entity_propagates_resolve_error,
     narrate_link_returns_prose,
     narrate_link_missing_subject,
     narrator_falls_back_to_template_on_backend_error,
     narrator_falls_back_to_template_on_backend_crash,
     narrate_template_entity_sentence,
     narrate_template_links_sentence,
     narrate_template_no_links,
     narrate_hecate_llm_calls_hecate_llm_chat,
     narrate_hecate_llm_uses_opts_model_override,
     narrate_hecate_llm_dark_mesh_returns_error
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
    %% passthrough: learn_truths_from_mesh's own tests override
    %% learn_link:learn/2 to assert on the call's args; every other
    %% test calls the real learn_link (itself backed by the mocked
    %% store above) unchanged.
    meck:new(learn_link, [passthrough]),
    Config.

end_per_testcase(_TestCase, _Config) ->
    meck:unload(hecate_graph_store),
    meck:unload(hecate_graph_facts),
    meck:unload(learn_link),
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

%% hecate_om <0.20.0 (this repo's own resolved version until an upstream
%% patch round on 2026-09-01) returned hecate_om_wire:field/2,3's VALUES
%% exactly as the wire decoded them -- a JSON string RPC arg decodes as a
%% CBOR text string, {text, binary()}, not a bare binary(). 0.20.0 fixed
%% field/2,3 to unwrap that before returning. Every other test in this
%% suite passes plain binaries directly and would pass identically
%% whether or not that fix (or this module's use of it) were broken --
%% this one specifically exercises the real wire shape, so a regression
%% here actually fails a test instead of silently passing on
%% synthetic-shaped test data. Would have badarg'd inside link_id/4's
%% binary concatenation on the pre-fix hecate_om, not just returned a
%% wrong value.
learn_link_handles_real_wire_shaped_values(_Config) ->
    mock_store_entity_exists(0),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        subject => {text, <<"did:macula:alice">>},
        predicate => {text, <<"knows">>},
        object => {text, <<"did:macula:bob">>}
    }),

    ?assertEqual(2, maps:get(entities_new, Result)),
    ?assert(is_binary(maps:get(link_id, Result))).

%% Phase 1 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): a caller supplied via
%% learn/2 becomes its own graph entity, asserted-linked to both the
%% subject and object it just told the graph about, at confidence 1.0.
learn_link_records_caller_provenance(_Config) ->
    mock_store_entity_exists(0),
    Published = mock_facts_collect_publish(),
    Caller = <<1, 2, 3, 4>>,
    CallerHex = binary:encode_hex(Caller, lowercase),

    {ok, _} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }, Caller),

    verify_entity_checked(CallerHex),

    Calls = store_run_calls(),
    AssertedCalls = [P || {_Q, P} <- Calls,
                          maps:get(<<"predicate">>, P, undefined) =:= <<"asserted">>],
    ?assertEqual(2, length(AssertedCalls)),
    ?assert(lists:any(fun(P) ->
        maps:get(<<"subject">>, P) =:= CallerHex andalso
        maps:get(<<"object">>, P) =:= <<"did:macula:alice">>
    end, AssertedCalls)),
    ?assert(lists:any(fun(P) ->
        maps:get(<<"subject">>, P) =:= CallerHex andalso
        maps:get(<<"object">>, P) =:= <<"did:macula:bob">>
    end, AssertedCalls)),
    ?assert(lists:all(fun(P) -> maps:get(<<"confidence">>, P) =:= 1.0 end, AssertedCalls)),

    timer:sleep(50),
    AssertedFacts = [F || F <- collect_facts(Published, link_learned),
                          maps:get(predicate, F) =:= <<"asserted">>],
    ?assertEqual(2, length(AssertedFacts)).

%% learn/1 (no caller -- the RPC path pre-macula-10.15.0, or any other
%% caller of the API) must not record any provenance: no third entity,
%% no asserted links. Regression guard for the opt-in gate.
learn_link_no_provenance_without_caller(_Config) ->
    mock_store_entity_exists(0),
    mock_facts_no_publish(),

    {ok, Result} = learn_link:learn(#{
        subject => <<"did:macula:alice">>,
        predicate => <<"knows">>,
        object => <<"did:macula:bob">>
    }),

    ?assertEqual(2, maps:get(entities_new, Result)),
    Calls = store_run_calls(),
    ?assertEqual([], [P || {_Q, P} <- Calls,
                           maps:get(<<"predicate">>, P, undefined) =:= <<"asserted">>]).

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
%% learn_truths_from_mesh tests (Phase 2)
%%====================================================================

truths_verified_publisher_gets_confidence_07(_Config) ->
    Publisher = <<1, 2, 3>>,
    Self = self(),
    meck:expect(learn_link, learn, fun(Params, Caller) ->
        Self ! {learn_called, Params, Caller},
        {ok, #{link_id => <<"x">>, entities_new => 2}}
    end),

    learn_truths_from_mesh:on_fact(
        <<"truth_asserted">>,
        #{subject => <<"a">>, predicate => <<"knows">>, object => <<"b">>},
        #{publisher => Publisher, publisher_verified => true}),

    receive
        {learn_called, Params, Caller} ->
            ?assertEqual(0.7, maps:get(confidence, Params)),
            ?assertEqual(Publisher, Caller)
    after 500 -> erlang:error(learn_link_not_called) end.

truths_unsigned_publisher_gets_confidence_04(_Config) ->
    Publisher = <<4, 5, 6>>,
    Self = self(),
    meck:expect(learn_link, learn, fun(Params, Caller) ->
        Self ! {learn_called, Params, Caller},
        {ok, #{link_id => <<"x">>, entities_new => 2}}
    end),

    learn_truths_from_mesh:on_fact(
        <<"truth_asserted">>,
        #{subject => <<"a">>, predicate => <<"knows">>, object => <<"b">>},
        #{publisher => Publisher, publisher_verified => not_signed}),

    receive
        {learn_called, Params, Caller} ->
            ?assertEqual(0.4, maps:get(confidence, Params)),
            ?assertEqual(Publisher, Caller)
    after 500 -> erlang:error(learn_link_not_called) end.

%% An older macula (pre-10.16.0) wouldn't put publisher_verified in Meta
%% at all -- must not crash, must degrade to the same confidence as
%% not_signed.
truths_missing_publisher_verified_key_degrades_gracefully(_Config) ->
    Publisher = <<13, 14, 15>>,
    Self = self(),
    meck:expect(learn_link, learn, fun(Params, Caller) ->
        Self ! {learn_called, Params, Caller},
        {ok, #{link_id => <<"x">>, entities_new => 2}}
    end),

    learn_truths_from_mesh:on_fact(
        <<"truth_asserted">>,
        #{subject => <<"a">>, predicate => <<"knows">>, object => <<"b">>},
        #{publisher => Publisher}),

    receive
        {learn_called, Params, Caller} ->
            ?assertEqual(0.4, maps:get(confidence, Params)),
            ?assertEqual(Publisher, Caller)
    after 500 -> erlang:error(learn_link_not_called) end.

%% An INVALID signature is a stronger negative signal than absence --
%% rejected outright, learn_link:learn/2 is never even called.
truths_invalid_signature_rejected(_Config) ->
    meck:expect(learn_link, learn, fun(_Params, _Caller) ->
        erlang:error(should_not_be_called)
    end),

    ok = learn_truths_from_mesh:on_fact(
        <<"truth_asserted">>,
        #{subject => <<"a">>, predicate => <<"knows">>, object => <<"b">>},
        #{publisher => <<7, 8, 9>>, publisher_verified => false}),

    ?assertEqual(0, meck:num_calls(learn_link, learn, '_')).

%% A learn_link failure (e.g. missing_required_fields from a malformed
%% fact) is logged, not crashed -- one bad mesh fact must not take the
%% subscriber down.
truths_learn_link_error_does_not_crash(_Config) ->
    meck:expect(learn_link, learn, fun(_Params, _Caller) ->
        {error, missing_required_fields}
    end),

    ok = learn_truths_from_mesh:on_fact(
        <<"truth_asserted">>,
        #{subject => <<"a">>, predicate => <<"knows">>, object => <<"b">>},
        #{publisher => <<10, 11, 12>>, publisher_verified => true}).

%%====================================================================
%% narrate_entity / narrate_link / hecate_graph_narrator tests (Phase 3)
%%====================================================================

narrate_entity_returns_prose(_Config) ->
    meck:new(resolve_entity, [passthrough]),
    meck:new(hecate_graph_narrator, [passthrough]),
    Entity = #{attributes => #{}, out_degree => 2, in_degree => 1, predicates => [<<"knows">>]},
    meck:expect(resolve_entity, resolve, fun(#{entity_id := <<"did:macula:alice">>}) ->
        {ok, Entity}
    end),
    meck:expect(hecate_graph_narrator, narrate, fun(Subgraph, _Opts) ->
        ?assertEqual(#{type => entity, entity_id => <<"did:macula:alice">>, entity => Entity}, Subgraph),
        {ok, <<"Alice knows two people.">>}
    end),

    {ok, Result} = narrate_entity:narrate(#{entity_id => <<"did:macula:alice">>}),

    ?assertEqual(<<"did:macula:alice">>, maps:get(entity_id, Result)),
    ?assertEqual(<<"Alice knows two people.">>, maps:get(prose, Result)),
    meck:unload(hecate_graph_narrator),
    meck:unload(resolve_entity).

narrate_entity_missing_entity_id(_Config) ->
    {error, missing_entity_id} = narrate_entity:narrate(#{}).

narrate_entity_propagates_resolve_error(_Config) ->
    meck:new(resolve_entity, [passthrough]),
    meck:expect(resolve_entity, resolve, fun(_) -> {error, entity_not_found} end),

    {error, entity_not_found} = narrate_entity:narrate(#{entity_id => <<"did:macula:nobody">>}),
    meck:unload(resolve_entity).

narrate_link_returns_prose(_Config) ->
    meck:new(resolve_link, [passthrough]),
    meck:new(hecate_graph_narrator, [passthrough]),
    Links = [#{predicate => <<"knows">>, object => <<"did:macula:bob">>,
               confidence => 1.0, source => <<"hecate-graph">>, learned_at => 0}],
    meck:expect(resolve_link, resolve, fun(#{subject := <<"did:macula:alice">>}) ->
        {ok, Links}
    end),
    meck:expect(hecate_graph_narrator, narrate, fun(Subgraph, _Opts) ->
        ?assertEqual(#{type => links, subject => <<"did:macula:alice">>, links => Links}, Subgraph),
        {ok, <<"Alice knows Bob.">>}
    end),

    {ok, Result} = narrate_link:narrate(#{subject => <<"did:macula:alice">>}),

    ?assertEqual(<<"did:macula:alice">>, maps:get(subject, Result)),
    ?assertEqual(<<"Alice knows Bob.">>, maps:get(prose, Result)),
    meck:unload(hecate_graph_narrator),
    meck:unload(resolve_link).

narrate_link_missing_subject(_Config) ->
    {error, missing_subject} = narrate_link:narrate(#{}).

%% hecate_graph_narrator's own fallback contract: ANY backend outcome
%% other than {ok, _} -- an {error, _} return or an outright crash --
%% falls through to narrate_template, never propagates as a failure.
narrator_falls_back_to_template_on_backend_error(_Config) ->
    meck:new(narrate_hecate_llm, [passthrough]),
    meck:expect(narrate_hecate_llm, narrate, fun(_, _) -> {error, mesh_not_ready} end),

    Subgraph = #{type => entity, entity_id => <<"x">>, entity => #{}},
    {ok, Prose} = hecate_graph_narrator:narrate(Subgraph, #{}),

    ?assert(is_binary(Prose)),
    meck:unload(narrate_hecate_llm).

narrator_falls_back_to_template_on_backend_crash(_Config) ->
    meck:new(narrate_hecate_llm, [passthrough]),
    meck:expect(narrate_hecate_llm, narrate, fun(_, _) -> erlang:error(boom) end),

    Subgraph = #{type => entity, entity_id => <<"x">>, entity => #{}},
    {ok, Prose} = hecate_graph_narrator:narrate(Subgraph, #{}),

    ?assert(is_binary(Prose)),
    meck:unload(narrate_hecate_llm).

%% narrate_template itself: deterministic, no mocking, cannot fail.
narrate_template_entity_sentence(_Config) ->
    Subgraph = #{type => entity, entity_id => <<"did:macula:alice">>,
                 entity => #{out_degree => 2, in_degree => 1, predicates => [<<"knows">>, <<"authored">>]}},
    {ok, Prose} = narrate_template:narrate(Subgraph, #{}),
    ?assert(binary:match(Prose, <<"did:macula:alice">>) =/= nomatch),
    ?assert(binary:match(Prose, <<"2">>) =/= nomatch),
    ?assert(binary:match(Prose, <<"knows">>) =/= nomatch).

narrate_template_links_sentence(_Config) ->
    Subgraph = #{type => links, subject => <<"did:macula:alice">>,
                 links => [#{predicate => <<"knows">>, object => <<"did:macula:bob">>}]},
    {ok, Prose} = narrate_template:narrate(Subgraph, #{}),
    ?assert(binary:match(Prose, <<"did:macula:alice">>) =/= nomatch),
    ?assert(binary:match(Prose, <<"knows">>) =/= nomatch),
    ?assert(binary:match(Prose, <<"did:macula:bob">>) =/= nomatch).

narrate_template_no_links(_Config) ->
    Subgraph = #{type => links, subject => <<"did:macula:alice">>, links => []},
    {ok, <<"No links found.">>} = narrate_template:narrate(Subgraph, #{}).

%% narrate_hecate_llm: the mesh-calling backend itself.
narrate_hecate_llm_calls_hecate_llm_chat(_Config) ->
    meck:new(hecate_om, [non_strict]),
    meck:new(hecate_om_identity, [non_strict]),
    meck:new(macula, [non_strict]),
    meck:expect(hecate_om, macula_client, fun() -> {ok, fake_pool} end),
    meck:expect(hecate_om_identity, realm, fun() -> {ok, <<"realm">>} end),
    meck:expect(macula, call, fun(fake_pool, <<"realm">>, <<"hecate-llm.chat">>, Payload, _Timeout) ->
        ?assertEqual(<<"moonshotai/kimi-k3">>, maps:get(<<"model">>, Payload)),
        Messages = maps:get(<<"messages">>, Payload),
        ?assertEqual(2, length(Messages)),
        {ok, #{content => <<"prose from nvidia">>}}
    end),

    Subgraph = #{type => entity, entity_id => <<"x">>, entity => #{}},
    {ok, <<"prose from nvidia">>} = narrate_hecate_llm:narrate(Subgraph, #{}),

    meck:unload(macula),
    meck:unload(hecate_om_identity),
    meck:unload(hecate_om).

narrate_hecate_llm_uses_opts_model_override(_Config) ->
    meck:new(hecate_om, [non_strict]),
    meck:new(hecate_om_identity, [non_strict]),
    meck:new(macula, [non_strict]),
    meck:expect(hecate_om, macula_client, fun() -> {ok, fake_pool} end),
    meck:expect(hecate_om_identity, realm, fun() -> {ok, <<"realm">>} end),
    meck:expect(macula, call, fun(fake_pool, <<"realm">>, <<"hecate-llm.chat">>, Payload, _Timeout) ->
        ?assertEqual(<<"some/other-model">>, maps:get(<<"model">>, Payload)),
        {ok, #{content => <<"ok">>}}
    end),

    Subgraph = #{type => entity, entity_id => <<"x">>, entity => #{}},
    {ok, <<"ok">>} = narrate_hecate_llm:narrate(Subgraph, #{model => <<"some/other-model">>}),

    meck:unload(macula),
    meck:unload(hecate_om_identity),
    meck:unload(hecate_om).

narrate_hecate_llm_dark_mesh_returns_error(_Config) ->
    meck:new(hecate_om, [non_strict]),
    meck:new(hecate_om_identity, [non_strict]),
    meck:expect(hecate_om, macula_client, fun() -> {error, not_connected} end),
    meck:expect(hecate_om_identity, realm, fun() -> {error, no_realm} end),

    Subgraph = #{type => entity, entity_id => <<"x">>, entity => #{}},
    {error, mesh_not_ready} = narrate_hecate_llm:narrate(Subgraph, #{}),

    meck:unload(hecate_om_identity),
    meck:unload(hecate_om).

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
