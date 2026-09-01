%%% @doc Top supervisor for hecate_graph.
%%%
%%% One child: hecate_graph_store — opens CozoDB, initialises schema, holds
%%% the NIF resource. hecate_graph_facts is NOT supervised here — it's a
%%% plain module of stateless fact-publishing functions (topic getters +
%%% `macula:publish/4` calls), not a gen_server, and has no start_link/0 to
%%% supervise.
-module(hecate_graph_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 30},
    Children = [worker(hecate_graph_store)],
    {ok, {SupFlags, Children}}.

worker(Module) ->
    #{id       => Module,
      start    => {Module, start_link, []},
      restart => permanent,
      shutdown => 5000,
      type    => worker,
      modules => [Module]}.
