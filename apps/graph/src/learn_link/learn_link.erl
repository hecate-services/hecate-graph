%%% @doc learn_link: record a relationship between two entities.
%%%
%%% This is the core write path. It:
%%%   1. Ensures the subject entity exists — if not, creates it and
%%%      publishes entity_learned
%%%   2. Ensures the object entity exists — if not, creates it and
%%%      publishes entity_learned
%%%   3. Inserts the link and publishes link_learned
%%%
%%% Entities are created implicitly — the caller does not need to
%%% pre-register them.
%%%
%%% "Already exists" is checked and resolved in ONE round trip via CozoDB's
%%% `:insert` (fails if the key already exists, unlike `:put' which always
%%% overwrites) rather than a separate exists-then-write pair of calls: two
%%% concurrent learn_link calls for the same brand-new entity would
%%% otherwise both observe "doesn't exist yet" and both publish
%%% entity_learned. `:insert`'s own key-uniqueness check is the
%%% synchronization primitive — exactly one of two racing inserts can
%%% succeed, so exactly one entity_learned fires.
%%%
%%% Registered as this service's `hecate_graph.learn_link` mesh procedure
%%% via `hecate_om_capabilities` (see hecate_graph_service:capabilities/0).
-module(learn_link).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([learn/1]).

%%====================================================================
%% macula_response
%%====================================================================

init(_Args) -> {ok, undefined}.

handle_request(Payload, State) ->
    case learn(Payload) of
        {ok, Result} -> {reply, Result, State};
        {error, Reason} -> {error, Reason, State}
    end.

%%====================================================================
%% API
%%====================================================================

%% RPC payloads decode with ATOM keys (macula_response's contract — the
%% same shape hecate_stations' list_stations.erl consumes), never binary
%% keys; a plain JSON HTTP body would decode binary-keyed, but that's a
%% different path this module doesn't serve.
-spec learn(map()) -> {ok, map()} | {error, term()}.
learn(#{subject := Subject,
        predicate := Predicate,
        object := Object} = Params) ->
    Confidence = maps:get(confidence, Params, 1.0),
    Metadata = maps:get(metadata, Params, #{}),
    Now = erlang:system_time(millisecond),
    Source = hecate_graph_facts:reporter(),
    ensure_subject(Subject, Predicate, Object, Confidence, Metadata, Now, Source);
learn(_Params) ->
    {error, missing_required_fields}.

%%====================================================================
%% Internal — sequential fallible steps, one function per step so each
%% only ever nests one `case' deep (subject -> object -> link -> publish).
%%====================================================================

ensure_subject(Subject, Predicate, Object, Confidence, Metadata, Now, Source) ->
    case ensure_entity(Subject, Metadata, Now, Source) of
        {error, _} = Error ->
            Error;
        {ok, SubjectNew} ->
            ensure_object(Subject, Predicate, Object, Confidence, Metadata, Now, Source, SubjectNew)
    end.

ensure_object(Subject, Predicate, Object, Confidence, Metadata, Now, Source, SubjectNew) ->
    case ensure_entity(Object, Metadata, Now, Source) of
        {error, _} = Error ->
            Error;
        {ok, ObjectNew} ->
            write_link(Subject, Predicate, Object, Confidence, Now, Source, SubjectNew, ObjectNew)
    end.

write_link(Subject, Predicate, Object, Confidence, Now, Source, SubjectNew, ObjectNew) ->
    LinkId = link_id(Subject, Predicate, Object, Now),
    case insert_link(LinkId, Subject, Predicate, Object, Confidence, Source, Now) of
        {error, _} = Error ->
            Error;
        ok ->
            publish_link(Subject, Predicate, Object, Confidence, Source, Now),
            {ok, #{link_id => LinkId, entities_new => SubjectNew + ObjectNew}}
    end.

%% Atomically create the entity if it doesn't exist yet, or report it as
%% already-known. `:insert' is the CozoDB primitive that makes this one
%% round trip instead of a check-then-write pair — see moduledoc.
ensure_entity(EntityId, Attributes, Now, Source) ->
    Query = <<"
        ?[id, attributes, first_seen, source] <- [[$entity_id, $attrs, $now, $source]]
        :insert entities { id => attributes, first_seen, source }
    ">>,
    Params = #{<<"entity_id">> => EntityId,
               <<"attrs">> => Attributes,
               <<"now">> => Now,
               <<"source">> => Source},
    case hecate_graph_store:run(Query, Params) of
        {ok, _} ->
            hecate_graph_facts:publish_entity_learned(
                #{entity_id => EntityId,
                  attributes => Attributes,
                  source => Source,
                  learned_at => Now}),
            {ok, 1};
        {error, Reason} ->
            already_known_or_error(already_exists(Reason), Reason)
    end.

already_known_or_error(true, _Reason) -> {ok, 0};
already_known_or_error(false, Reason) -> {error, Reason}.

%% CozoDB's `:insert' key-collision error message contains "already exist"
%% (cozo-core's own wording); anything else is a genuine failure (bad
%% query, store unavailable) that must propagate, not be swallowed as
%% "fine, it already existed".
already_exists(Reason) ->
    ReasonBin = reason_to_binary(Reason),
    binary:match(ReasonBin, <<"already exist">>) =/= nomatch.

reason_to_binary(Reason) when is_binary(Reason) -> Reason;
reason_to_binary(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

insert_link(LinkId, Subject, Predicate, Object, Confidence, Source, Now) ->
    Query = <<"
        ?[link_id, subject, predicate, object, confidence, source, learned_at]
        <- [[$link_id, $subject, $predicate, $object, $confidence, $source, $now]]
        :put links { link_id => subject, predicate, object, confidence, source, learned_at }
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
            {error, Reason}
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
