%%% @doc Phase 3 default narrator backend: calls hecate-llm.chat over
%%% the mesh rather than carrying an LLM API key/HTTP client locally --
%%% hecate-llm exists specifically so services don't each duplicate
%%% that. See hecate-services/hecate-llm.
%%%
%%% NVIDIA's free tier is the cost-driven default model (2026-09-02
%%% decision -- Melious priced out at this stage; Melious itself stays
%%% wired into hecate-llm's own provider list for when that changes,
%%% just not this service's default). `narrator_model' is app-env
%%% configurable specifically so it can be repointed post-deploy
%%% without a code change once hecate-llm's own model detection
%%% confirms what's actually live.
-module(narrate_hecate_llm).
-behaviour(hecate_graph_narrator).

-export([narrate/2]).

-define(PROCEDURE, <<"hecate-llm.chat">>).
-define(TIMEOUT_MS, 30_000).
-define(SYSTEM_PROMPT,
    <<"You describe graph database query results in plain prose. "
      "One or two sentences, no preamble, no markdown.">>).

-spec narrate(map(), map()) -> {ok, binary()} | {error, term()}.
narrate(Subgraph, Opts) ->
    Model = model(maps:get(model, Opts, undefined)),
    Messages = [
        #{<<"role">> => <<"system">>, <<"content">> => ?SYSTEM_PROMPT},
        #{<<"role">> => <<"user">>, <<"content">> => prompt(Subgraph)}
    ],
    call_chat(Model, Messages).

%% A caller-supplied `model' in Opts wins (narrate_entity/narrate_link
%% both thread hecate_om_wire:field(model, Params) through, so an RPC
%% caller can ask for a specific model per call); the app-env default
%% otherwise. NVIDIA's own catalog needs "org/model"-namespaced ids
%% (bare "glm-5.2" 404s; "moonshotai/kimi-k3" is the confirmed-working
%% one this account has -- see this workspace's own opencode.json for
%% the same finding against the same NVIDIA_API_KEY).
model(undefined) ->
    application:get_env(hecate_graph, narrator_model, <<"moonshotai/kimi-k3">>);
model(Model) when is_binary(Model) ->
    Model.

call_chat(Model, Messages) ->
    connect({hecate_om:macula_client(), hecate_om_identity:realm()}, Model, Messages).

connect({{ok, Pool}, {ok, Realm}}, Model, Messages) ->
    Payload = #{<<"model">> => Model, <<"messages">> => Messages},
    reply(catch macula:call(Pool, Realm, ?PROCEDURE, Payload, ?TIMEOUT_MS));
connect(_DarkOrNoRealm, _Model, _Messages) ->
    {error, mesh_not_ready}.

reply({ok, Response}) ->
    content(hecate_om_wire:field(content, Response));
reply({error, _} = Error) ->
    Error;
reply(Caught) ->
    {error, {mesh_call_failed, Caught}}.

content(undefined) -> {error, empty_response};
content(<<>>)      -> {error, empty_response};
content(Content)   -> {ok, Content}.

%%====================================================================
%% Prompt construction
%%====================================================================

prompt(#{type := entity, entity_id := EntityId, entity := Entity}) ->
    OutDeg = maps:get(out_degree, Entity, 0),
    InDeg = maps:get(in_degree, Entity, 0),
    Predicates = maps:get(predicates, Entity, []),
    Attributes = maps:get(attributes, Entity, #{}),
    iolist_to_binary([
        <<"Entity: ">>, EntityId, <<"\n">>,
        <<"Outgoing links: ">>, integer_to_binary(OutDeg), <<"\n">>,
        <<"Incoming links: ">>, integer_to_binary(InDeg), <<"\n">>,
        <<"Link types: ">>, format_list(Predicates), <<"\n">>,
        <<"Attributes: ">>, format_map(Attributes)
    ]);
prompt(#{type := links, subject := Subject, links := Links}) ->
    iolist_to_binary([
        <<"Subject: ">>, Subject, <<"\n">>,
        <<"Links:\n">>,
        [format_triple(Subject, L) || L <- Links]
    ]).

format_triple(Subject, #{predicate := Predicate, object := Object}) ->
    [<<"- ">>, Subject, <<" ">>, Predicate, <<" ">>, Object, <<"\n">>].

format_list([]) -> <<"(none)">>;
format_list(List) -> lists:join(<<", ">>, List).

format_map(Map) when map_size(Map) =:= 0 -> <<"(none)">>;
format_map(Map) -> iolist_to_binary(io_lib:format("~p", [Map])).
