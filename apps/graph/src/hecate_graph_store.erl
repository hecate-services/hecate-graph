%%% @doc CozoDB store wrapper — opens the database, initialises the schema,
%%% and provides the query API used by learn_link / resolve_link / resolve_entity.
%%%
%%% The CozoDB resource handle is held in this gen_server's state. All
%%% queries go through run/2 or run_script/2, which call the NIF.
%%%
%%% Schema (two relations):
%%%
%%%   entities — one row per known entity (implicitly created by learn_link)
%%%     id         String  (primary key, e.g. "did:macula:abc")
%%%     attributes Json    (flexible metadata bag)
%%%     first_seen Int     (epoch ms when first learned)
%%%     source     String  (which instance learned it)
%%%
%%%   links — one row per association (subject → predicate → object)
%%%     subject    String  (entity id)
%%%     predicate  String  (relationship type, e.g. "authored")
%%%     object     String  (entity id)
%%%     confidence Float   (0.0–1.0)
%%%     source     String  (which instance learned it)
%%%     learned_at Int     (epoch ms)
%%%     link_id    String  (sha256(subject|predicate|object|learned_at), primary key)
-module(hecate_graph_store).
-behaviour(gen_server).

-export([start_link/0, is_open/0, run/2, run_script/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% `id' / `link_id' are the sole KEY columns (before `=>'); every other
%% column is a VALUE column that `:put'/`:insert' can write and `:update'
%% can revise without touching the key. Without the `=>' split, CozoDB
%% treats every listed column as part of the key -- `:put'-ing an existing
%% id with different attributes would silently insert a SECOND row instead
%% of overwriting the first, which breaks both learn_link's upsert
%% semantics and the atomic `:insert'-fails-if-exists check ensure_entity/4
%% relies on to detect "was this entity already known" in one round trip.
%%
%% Real secondary indexes via `::index create' (`:create idx {...}' creates
%% an unrelated, never-populated base relation -- it is not how CozoDB
%% indexes anything). `entities' needs none: `id' is already its primary
%% key, so a point lookup by id is already O(1) via the key itself.
%% Binary literals, not plain strings -- the NIF decodes its script
%% argument as a Rust String, which rustler only accepts from an Erlang
%% BINARY. A charlist here would hit the exact same badarg the data_dir
%% path argument did (see init/1's own note) the moment schema init runs,
%% right after a successful open/1.
%%
%% THREE separate scripts, not one: CozoDB's own rule is that a `::`
%% system op "must appear alone in a script" -- confirmed live, the
%% combined single-script version (relations + both ::index create
%% lines) failed to parse at all, "unexpected input" right at the first
%% `::index create` line, on the very first real boot with a working NIF.
-define(SCHEMA_RELATIONS, <<"
    :create entities {
        id: String
        =>
        attributes: Json default {},
        first_seen: Int,
        source: String
    }

    :create links {
        link_id: String
        =>
        subject: String,
        predicate: String,
        object: String,
        confidence: Float default 1.0,
        source: String,
        learned_at: Int
    }
">>).

-define(INDEX_LINKS_SUBJECT, <<"::index create links:idx_links_subject {subject}">>).
-define(INDEX_LINKS_OBJECT, <<"::index create links:idx_links_object {object}">>).

-record(state, {
    resource :: reference() | undefined,
    data_dir :: file:filename()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec is_open() -> boolean().
is_open() ->
    case whereis(?MODULE) of
        undefined -> false;
        _Pid -> gen_server:call(?MODULE, is_open)
    end.

-spec run(binary(), map()) -> {ok, map()} | {error, term()}.
run(Query, Params) ->
    gen_server:call(?MODULE, {run, Query, Params}, 30000).

-spec run_script(binary()) -> {ok, map()} | {error, term()}.
run_script(Script) ->
    gen_server:call(?MODULE, {run_script, Script}, 30000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    DataDir = application:get_env(hecate_graph, data_dir, "/var/lib/hecate-graph"),
    ok = filelib:ensure_dir(filename:join(DataDir, "dummy")),
    %% The NIF's `open/1` decodes its argument as a Rust String, which
    %% rustler only accepts from an Erlang BINARY, not the charlist
    %% `sys.config.src`'s `{data_dir, "..."}` actually produces --
    %% confirmed live: passing the charlist through raised `badarg` deep
    %% inside the NIF call, surfacing as hecate_graph_store's own
    %% supervisor failing to start with no clearer signal than that.
    open_store(hecate_graph_nif:open(unicode:characters_to_binary(DataDir)), DataDir).

open_store({ok, Resource}, DataDir) ->
    init_with_schema(init_schema(Resource), Resource, DataDir);
open_store({error, nif_not_loaded} = Error, _DataDir) ->
    logger:error("hecate_graph_store: CozoDB NIF not loaded — "
                 "graph service cannot function without it"),
    {stop, Error};
open_store({error, Reason} = Error, _DataDir) ->
    logger:error("hecate_graph_store: CozoDB open failed: ~p", [Reason]),
    {stop, Error}.

init_with_schema(ok, Resource, DataDir) ->
    logger:info("hecate_graph_store opened CozoDB at ~s", [DataDir]),
    {ok, #state{resource = Resource, data_dir = DataDir}};
init_with_schema({error, Reason} = Error, _Resource, _DataDir) ->
    logger:error("hecate_graph_store schema init failed: ~p", [Reason]),
    {stop, Error}.

handle_call(is_open, _From, #state{resource = R} = State) ->
    {reply, R =/= undefined, State};

handle_call({run, Query, Params}, _From, #state{resource = R} = State) ->
    Result = hecate_graph_nif:run_query(R, Query, Params),
    {reply, Result, State};

handle_call({run_script, Script}, _From, #state{resource = R} = State) ->
    Result = hecate_graph_nif:run_script(R, Script),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{resource = R}) when R =/= undefined ->
    catch hecate_graph_nif:close(R),
    ok;
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

init_schema(Resource) ->
    case run_schema_step(Resource, ?SCHEMA_RELATIONS) of
        ok -> init_index_subject(Resource);
        {error, _} = Error -> Error
    end.

init_index_subject(Resource) ->
    case run_schema_step(Resource, ?INDEX_LINKS_SUBJECT) of
        ok -> init_index_object(Resource);
        {error, _} = Error -> Error
    end.

init_index_object(Resource) ->
    run_schema_step(Resource, ?INDEX_LINKS_OBJECT).

run_schema_step(Resource, Script) ->
    case hecate_graph_nif:run_script(Resource, Script) of
        {ok, _} -> ok;
        {error, Reason} -> handle_schema_error(Reason)
    end.

%% Restart idempotency: on any boot after the first, `:create'/`::index
%% create' hit relations/indexes the previous boot already made. CozoDB's
%% real wording for that, confirmed live on a genuine restart, is
%% "Stored relation links conflicts with an existing one" -- NOT
%% "already exists", which this checked for originally and which never
%% matched, so every restart after the first crashed the whole service
%% on a schema step that should have been a silent no-op. Checking for
%% both substrings since index-creation conflicts weren't observed
%% directly and may word it differently.
%%
%% A SECOND, independent bug in the original version of this fix: cozo's
%% error messages (rendered via miette) carry ANSI colour escape codes,
%% so `Reason' is a binary that STARTS with byte 27 (ESC). Erlang's `~p'
%% formatter treats that as "not printable" and renders the whole binary
%% as a comma-separated list of decimal byte values instead of the
%% actual text -- confirmed live: the crash log itself showed
%% `<<27,91,51,49,109,...>>', not the readable message. Substring
%% matching THAT against "conflicts with an existing" can never succeed,
%% no matter how correct the substring itself is. `learn_link:
%% reason_to_binary/1' already had the right guard (use a binary Reason
%% directly, skip `io_lib:format' entirely); this module didn't, and
%% that inconsistency -- not the substring text -- was the actual live
%% bug.
handle_schema_error(Reason) ->
    ReasonStr = reason_to_binary(Reason),
    AlreadyExists = binary:match(ReasonStr, <<"already exist">>) =/= nomatch,
    Conflicts = binary:match(ReasonStr, <<"conflicts with an existing">>) =/= nomatch,
    case AlreadyExists orelse Conflicts of
        false -> {error, Reason};
        true -> ok
    end.

reason_to_binary(Reason) when is_binary(Reason) -> Reason;
reason_to_binary(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
