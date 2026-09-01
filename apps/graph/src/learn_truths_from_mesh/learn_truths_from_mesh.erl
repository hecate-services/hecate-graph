%%% @doc Phase 2 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): passive ingestion
%%% from the mesh, alongside `learn_link''s active/pull RPC path.
%%%
%%% Subscribes to `hecate_graph_facts:truth_asserted_topic/0' and, for
%%% each `{subject, predicate, object, confidence?, source?}' fact,
%%% calls the SAME `learn_link:learn/2' entry point the RPC path already
%%% uses -- no new write path, no new ensure_entity/insert_link logic.
%%% The mesh `publisher' fills `learn/2''s `Caller' slot, so the
%%% publisher becomes a graph entity here exactly like an RPC caller
%%% does in Phase 1 (`publisher --asserted--> subject/object'),
%%% unifying both ingestion paths onto one provenance model.
%%%
%%% Deliberately NOT a translator for hecate-mail's `message.sent',
%%% hecate-tube's `video.published', or any other producer's own domain
%%% events -- that doesn't scale and recouples this service to
%%% everyone else's wire formats. One shared, opt-in contract: a
%%% producer that wants to feed the graph publishes `truth_asserted'
%%% itself (see hecate-sentinel's/hecate-news's own PM for that).
%%%
%%% Confidence is NOT the fact's own optional `confidence' field --
%%% it's set by provenance quality, per the plan's own table:
%%%
%%%   publisher_verified = true       -> 0.7 (signed, checked out)
%%%   publisher_verified = not_signed -> 0.4 (identified, unsigned)
%%%   publisher_verified = false      -> REJECTED, not recorded at a
%%%                                       lower confidence -- an
%%%                                       actively invalid signature is
%%%                                       a stronger negative signal
%%%                                       than never having one, and
%%%                                       the plan's table has no row
%%%                                       for it because Phase 1 never
%%%                                       reaches this state on the RPC
%%%                                       side (a caller can't forge
%%%                                       the wire-authenticated field
%%%                                       macula itself extracts).
%%%     Needs macula >= 10.16.0 for `publisher_verified' to be
%%%     anything but `not_signed' -- see that release's own CHANGELOG.
%%%
%%% Re-subscribes on teardown (`macula_event_gone'). Degrades safely
%%% while the mesh is dark, same pattern hecate-sentinel's
%%% `ingest_warden_reports' already established for this exact shape
%%% of problem.
-module(learn_truths_from_mesh).
-behaviour(gen_server).

-export([start_link/0]).
-export([on_fact/3]).  %% exported for tests
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RESUB_MS, 5_000).
-define(VERIFIED_CONFIDENCE, 0.7).
-define(UNSIGNED_CONFIDENCE, 0.4).

-record(st, {sub :: reference() | undefined}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    self() ! subscribe,
    {ok, #st{}}.

handle_call(_Req, _From, St) -> {reply, {error, unknown_call}, St}.
handle_cast(_Msg, St)        -> {noreply, St}.

handle_info(subscribe, St) ->
    {noreply, do_subscribe(St)};
handle_info({macula_event, _Ref, Topic, Payload, Meta}, St) ->
    on_fact(Topic, Payload, Meta),
    {noreply, St};
handle_info({macula_event_gone, _Ref, _Reason}, St) ->
    self() ! subscribe,
    {noreply, St#st{sub = undefined}};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%%====================================================================
%% Internal
%%====================================================================

do_subscribe(St) ->
    connect({hecate_om:macula_client(), hecate_om_identity:realm()}, St).

connect({{ok, Pool}, {ok, Realm}}, St) ->
    subscribed(catch macula:subscribe(Pool, Realm, hecate_graph_facts:truth_asserted_topic(), self()), St);
connect(_DarkOrNoRealm, St) ->
    resub(St).

subscribed({ok, Ref}, St) -> St#st{sub = Ref};
subscribed(_Failed, St)   -> resub(St).

resub(St) ->
    erlang:send_after(?RESUB_MS, self(), subscribe),
    St.

on_fact(Topic, Payload, Meta) ->
    learn(Payload, publisher_confidence(Meta), maps:get(publisher, Meta, undefined), Topic).

%% `false' (signature present but invalid) is a stronger negative
%% signal than absence -- reject outright, don't record at a merely
%% low confidence. See moduledoc.
%% `hecate_om''s own macula dep is a loose `~> 10.0' (via hecate-graph's
%% `~> 0.22' on hecate_om) -- nothing pins it to >= 10.16.0 specifically,
%% so a resolution that lands on an older macula is possible even though
%% unlikely in practice. `publisher_verified' would simply be absent
%% from Meta then, not present-and-wrong -- treat that exactly like
%% `not_signed', the honest "we don't know" answer, not a crash.
publisher_confidence(#{publisher_verified := true})       -> ?VERIFIED_CONFIDENCE;
publisher_confidence(#{publisher_verified := not_signed}) -> ?UNSIGNED_CONFIDENCE;
publisher_confidence(#{publisher_verified := false})      -> reject;
publisher_confidence(_NoPublisherVerifiedKey)              -> ?UNSIGNED_CONFIDENCE.

learn(_Payload, reject, _Publisher, Topic) ->
    logger:warning("learn_truths_from_mesh: dropping ~s fact, "
                    "publisher_sig present but invalid", [Topic]),
    ok;
learn(Payload, Confidence, Publisher, _Topic) ->
    %% subject/predicate/object presence is learn_link:learn/2's own
    %% validation to make (missing_required_fields) -- not duplicated
    %% here. `confidence' overrides whatever the payload itself may
    %% have supplied: provenance quality decides what we record, not
    %% the producer's own claim about its fact.
    Params = Payload#{confidence => Confidence},
    case learn_link:learn(Params, Publisher) of
        {ok, _Result} ->
            ok;
        {error, Reason} ->
            logger:warning("learn_truths_from_mesh: learn_link:learn/2 "
                            "failed: ~p", [Reason])
    end.
