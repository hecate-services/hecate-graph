%%% @doc hecate_graph OTP application entry.
%%%
%%% Boots hecate_om (mesh wiring + capabilities + health) then starts the
%%% graph supervisor, which opens the CozoDB instance and initialises the
%%% schema.
-module(hecate_graph_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hecate_om:boot(hecate_graph_service).

stop(_State) ->
    ok.
