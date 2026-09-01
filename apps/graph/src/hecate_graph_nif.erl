%%% @doc Rustler NIF wrapper for CozoDB.
%%%
%%% All NIF calls go through this module. If the NIF is not loaded (no
%%% Rust toolchain at build time), every function returns {error, nif_not_loaded}.
%%% There is no pure-Erlang fallback for a graph database — without CozoDB
%%% the service cannot function.
%%%
%%% The NIF resource (a CozoDB instance handle) is held in the process
%%% state of hecate_graph_store, not here — this module is stateless.
-module(hecate_graph_nif).

-export([
    open/1,
    run_query/3,
    run_script/2,
    close/1,
    backup/2,
    restore/2,
    is_loaded/0
]).

-on_load(on_load/0).

-define(NIF_LIB, "hecate_graph_nif").

on_load() ->
    case erlang:load_nif(?NIF_LIB, 0) of
        ok -> ok;
        {error, {load_failed, _}} -> ok;
        {error, _} -> ok
    end.

-spec is_loaded() -> boolean().
is_loaded() ->
    erlang:function_exported(?MODULE, open, 1).

-spec open(file:filename()) -> {ok, reference()} | {error, term()}.
open(_Path) ->
    {error, nif_not_loaded}.

-spec run_query(reference(), binary(), map()) -> {ok, map()} | {error, term()}.
run_query(_Resource, _Query, _Params) ->
    {error, nif_not_loaded}.

-spec run_script(reference(), binary()) -> {ok, map()} | {error, term()}.
run_script(_Resource, _Script) ->
    {error, nif_not_loaded}.

-spec close(reference()) -> ok | {error, term()}.
close(_Resource) ->
    {error, nif_not_loaded}.

-spec backup(reference(), file:filename()) -> ok | {error, term()}.
backup(_Resource, _Path) ->
    {error, nif_not_loaded}.

-spec restore(reference(), file:filename()) -> ok | {error, term()}.
restore(_Resource, _Path) ->
    {error, nif_not_loaded}.
