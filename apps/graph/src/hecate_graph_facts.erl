%%% @doc Fact definitions for hecate_graph.
%%%
%%% Two fact types are published to the mesh:
%%%
%%%   entity_learned — a new entity was implicitly created by learn_link.
%%%     type = entity_learned, entity_id = "did:macula:abc",
%%%     source = "hecate-graph/node-3", learned_at = 1788244318000
%%%
%%%   link_learned — a new relationship was recorded.
%%%     type = link_learned, subject = "did:macula:abc",
%%%     predicate = "authored", object = "did:macula:def",
%%%     confidence = 0.95, source = "hecate-graph/node-3",
%%%     learned_at = 1788244318000
%%%
%%% A consumer composing a knowledge graph subscribes to both topics and
%%% upserts vertices (entity_learned) and edges (link_learned) into its
%%% own local graph.
-module(hecate_graph_facts).

-export([
    entity_learned_topic/0,
    link_learned_topic/0,
    truth_asserted_topic/0,
    publish_entity_learned/1,
    publish_link_learned/1,
    reporter/0
]).

-define(REPORTER, <<"hecate-graph">>).

-spec entity_learned_topic() -> binary().
entity_learned_topic() ->
    to_binary(application:get_env(hecate_graph, entity_learned_topic, <<"entity_learned">>)).

-spec link_learned_topic() -> binary().
link_learned_topic() ->
    to_binary(application:get_env(hecate_graph, link_learned_topic, <<"link_learned">>)).

%% @doc Phase 2 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): the shared, opt-in
%% topic willing producers (hecate-sentinel, hecate-news, ...) publish
%% `{subject, predicate, object, confidence?, source?}' facts onto.
%% hecate-graph only SUBSCRIBES here (see learn_truths_from_mesh) --
%% unlike entity_learned/link_learned, which this instance itself
%% publishes for other hecate-graph instances to compose from,
%% truth_asserted is a cross-service contract this instance consumes,
%% not one it produces. Flat, unprefixed name matching entity_learned/
%% link_learned's own sibling style (and every other producer's `NOUN
%% past-tense verb' facts already live on this mesh) -- not the
%% "mesh.truth_asserted" dot-namespaced guess the plan drafted before
%% checking. No other topic on this mesh uses a "mesh." prefix.
-spec truth_asserted_topic() -> binary().
truth_asserted_topic() ->
    to_binary(application:get_env(hecate_graph, truth_asserted_topic, <<"truth_asserted">>)).

-spec publish_entity_learned(map()) -> ok.
publish_entity_learned(#{entity_id := _EntityId} = Fact) ->
    Full = Fact#{type => entity_learned,
                  schema_v => 1,
                  source => maps:get(source, Fact, ?REPORTER),
                  learned_at => maps:get(learned_at, Fact, erlang:system_time(millisecond))},
    publish(entity_learned_topic(), Full).

-spec publish_link_learned(map()) -> ok.
publish_link_learned(#{subject := _, predicate := _, object := _} = Fact) ->
    Full = Fact#{type => link_learned,
                 schema_v => 1,
                 source => maps:get(source, Fact, ?REPORTER),
                 learned_at => maps:get(learned_at, Fact, erlang:system_time(millisecond))},
    publish(link_learned_topic(), Full).

-spec reporter() -> binary().
reporter() -> ?REPORTER.

%%====================================================================
%% Internal
%%====================================================================

publish(Topic, Fact) ->
    emit(catch {hecate_om:macula_client(), hecate_om_identity:realm()}, Topic, Fact).

emit({{ok, Pool}, {ok, Realm}}, Topic, Fact) ->
    catch macula:publish(Pool, Realm, Topic, Fact),
    ok;
emit(_DarkOrNoRealm, _Topic, _Fact) ->
    ok.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).
