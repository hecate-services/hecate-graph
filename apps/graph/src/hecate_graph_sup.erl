%%% @doc Top supervisor for hecate_graph.
%%%
%%% Two children, started in order:
%%%   1. hecate_graph_store — opens CozoDB, initialises schema, holds the NIF resource
%%%   2. hecate_graph_facts  — mesh procedure handlers (resolve/learn)
%%%
%%% rest_for_one: if the store dies, the facts handler must restart too
%%% (it depends on the store being open).
-module(hecate_graph_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 30},
    Children = [
        worker(hecate_graph_store),
        worker(hecate_graph_facts)
    ],
    {ok, {SupFlags, Children}}.

worker(Module) ->
    #{id       => Module,
      start    => {Module, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type    => worker,
      modules => [Module]}.
