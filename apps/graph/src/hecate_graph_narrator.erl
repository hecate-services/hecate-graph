%%% @doc Phase 3 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): pluggable prose
%%% backend for narrate_entity/narrate_link.
%%%
%%% Deliberately its OWN behaviour, not a `format' parameter on
%%% resolve_entity/resolve_link: an LLM-backed call has a fundamentally
%%% different cost/latency/failure profile than a local Cozo query, and
%%% bundling them would make one procedure's latency bimodal and stop a
%%% realm operator from disabling narration alone.
%%%
%%% The configured backend (`narrator_backend' app env, default
%%% narrate_hecate_llm) gets first try; ANY failure -- `{error, _}',
%%% a crash, an unreachable mesh -- falls through to narrate_template's
%%% deterministic sentence-per-triple rendering, never a hard failure.
%%% Same graceful-degrade precedent this codebase already has for the
%%% CozoDB NIF itself (`{error, nif_not_loaded}', never a crash).
-module(hecate_graph_narrator).

-export([narrate/2]).

-callback narrate(Subgraph :: map(), Opts :: map()) ->
    {ok, binary()} | {error, term()}.

-spec narrate(map(), map()) -> {ok, binary()}.
narrate(Subgraph, Opts) ->
    Backend = application:get_env(hecate_graph, narrator_backend, narrate_hecate_llm),
    fallback_if_needed(catch Backend:narrate(Subgraph, Opts), Subgraph, Opts).

fallback_if_needed({ok, Prose}, _Subgraph, _Opts) ->
    {ok, Prose};
fallback_if_needed({error, Reason}, Subgraph, Opts) ->
    logger:info("hecate_graph_narrator: backend failed (~p), falling back to template", [Reason]),
    narrate_template:narrate(Subgraph, Opts);
fallback_if_needed(_Caught, Subgraph, Opts) ->
    logger:warning("hecate_graph_narrator: backend crashed, falling back to template"),
    narrate_template:narrate(Subgraph, Opts).
