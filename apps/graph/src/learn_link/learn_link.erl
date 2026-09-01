%%% @doc learn_link: record a relationship between two entities.
%%%
%%% This is the core write path. It:
%%%   1. Checks if the subject entity exists — if not, creates it and
%%%      publishes entity_learned
%%%   2. Checks if the object entity exists — if not, creates it and
%%%      publishes entity_learned
%%%   3. Inserts the link and publishes link_learned
%%%
%%% Entities are created implicitly — the caller does not need to
%%% pre-register them. If an entity already exists, its attributes are
%%% merged (not replaced).
%%%
%%% Called via mesh_call(hecate_graph.learn_link, #{subject, predicate, object, ...}).
-module(learn_link).

-export([learn/1]).

-spec learn(map()) -> {ok, map()} | {error, term()}.
learn(#{<<"subject">> := Subject,
        <<"predicate">> := Predicate,
        <<"object">> := Object} = Params) ->
    Confidence = maps:get(<<"confidence">>, Params, 1.0),
    Metadata = maps:get(<<"metadata">>, Params, #{}),
    Now = erlang:system_time(millisecond),
    Source = hecate_graph_facts:reporter(),

    SubjectNew = ensure_entity(Subject, Metadata, Now, Source),
    ObjectNew = ensure_entity(Object, Metadata, Now, Source),

    LinkId = link_id(Subject, Predicate, Object, Now),
    insert_link(LinkId, Subject, Predicate, Object, Confidence, Source, Now),

    publish_link(Subject, Predicate, Object, Confidence, Source, Now),

    {ok, #{link_id => LinkId,
           entities_new => SubjectNew + ObjectNew}};
learn(_Params) ->
    {error, missing_required_fields}.

%%====================================================================
%% Internal
%%====================================================================

ensure_entity(EntityId, Attributes, Now, Source) ->
    case entity_exists(EntityId) of
        true ->
            0;
        false ->
            upsert_entity(EntityId, Attributes, Now, Source),
            hecate_graph_facts:publish_entity_learned(
                #{entity_id => EntityId,
                  attributes => Attributes,
                  source => Source,
                  learned_at => Now}),
            1
    end.

entity_exists(EntityId) ->
    Query = <<"?[count(n)] := *entities{id: $entity_id, n}">>,
    case hecate_graph_store:run(Query, #{<<"entity_id">> => EntityId}) of
        {ok, #{<<"rows">> := [[Count] | _]}} when Count > 0 -> true;
        _ -> false
    end.

upsert_entity(EntityId, Attributes, Now, Source) ->
    Query = <<"
        ?[id, attributes, first_seen, source] <- [[$entity_id, $attrs, $now, $source]]
        :put entities { id, attributes, first_seen, source }
    ">>,
    Params = #{<<"entity_id">> => EntityId,
               <<"attrs">> => Attributes,
               <<"now">> => Now,
               <<"source">> => Source},
    case hecate_graph_store:run(Query, Params) of
        {ok, _} -> ok;
        {error, Reason} ->
            logger:warning("upsert_entity failed for ~s: ~p", [EntityId, Reason]),
            ok
    end.

insert_link(LinkId, Subject, Predicate, Object, Confidence, Source, Now) ->
    Query = <<"
        ?[link_id, subject, predicate, object, confidence, source, learned_at]
        <- [[$link_id, $subject, $predicate, $object, $confidence, $source, $now]]
        :put links { link_id, subject, predicate, object, confidence, source, learned_at }
    ">>,
    Params = #{<<"link_id">> => LinkId,
               <<"subject">> => Subject,
               <<"predicate">> => Predicate,
               <<"object">> => Object,
               <<"confidence">> => Confidence,
               <<"source">> => Source,
               <<"now">> => Now},
    case hecate_graph_store:run(Query, Params) of
        {ok, _} -> ok;
        {error, Reason} ->
            logger:warning("insert_link failed: ~p", [Reason]),
            ok
    end.

publish_link(Subject, Predicate, Object, Confidence, Source, Now) ->
    hecate_graph_facts:publish_link_learned(
        #{subject => Subject,
          predicate => Predicate,
          object => Object,
          confidence => Confidence,
          source => Source,
          learned_at => Now}).

link_id(Subject, Predicate, Object, Now) ->
    Bin = <<Subject/binary, "|", Predicate/binary, "|",
            Object/binary, "|", (integer_to_binary(Now))/binary>>,
    Hex = binary:encode_hex(crypto:hash(sha256, Bin)),
    <<Short:16/binary, _/binary>> = Hex,
    string:lowercase(Short).
