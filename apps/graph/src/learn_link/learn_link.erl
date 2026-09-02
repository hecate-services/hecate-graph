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
%%% `:insert' (fails if the key already exists, unlike `:put' which always
%%% overwrites) rather than a separate exists-then-write pair of calls: two
%%% concurrent learn_link calls for the same brand-new entity would
%%% otherwise both observe "doesn't exist yet" and both publish
%%% entity_learned. The `:insert' operation's own key-uniqueness check is
%%% the synchronization primitive — exactly one of two racing inserts can
%%% succeed, so exactly one entity_learned fires.
%%%
%%% Registered as this service's `hecate_graph.learn_link' mesh procedure
%%% via `hecate_om_capabilities' (see hecate_graph_service:capabilities/0).
%%%
%%% Phase 1 (PLAN_MESH_TRUTHS_AND_PROVENANCE.md): the caller becomes part
%%% of the graph too. With macula >= 10.15.0, hecate_om_wire:caller/1
%%% reads the wire-authenticated identity that made this RPC (undefined
%%% on an older macula or a payload that arrived some other way -- both
%%% just skip provenance, same as "the caller supplied no metadata"
%%% skips it today). When present, two extra links are recorded reusing
%%% the SAME ensure_entity/insert_link machinery the subject/object link
%%% already uses -- caller --asserted--> subject, caller --asserted-->
%%% object -- at confidence 1.0 (a direct, wire-authenticated RPC call is
%%% the plan's own highest-confidence provenance tier). Coarser than
%%% per-triple reification (caller asserted THIS SPECIFIC link, not just
%%% touched its endpoints) on purpose -- see the plan's Phase 1 section
%%% for why that's deliberately out of scope for now.
-module(learn_link).

-behaviour(macula_response).

-export([init/1, handle_request/2]).
-export([learn/1, learn/2]).

%% Confidence for a caller's own provenance link, not the asserted fact
%% itself -- we are not uncertain that the caller made this call.
-define(PROVENANCE_CONFIDENCE, 1.0).
-define(ASSERTED, <<"asserted">>).
-define(PROCEDURE, <<"hecate_graph.learn_link">>).

%%====================================================================
%% macula_response
%%====================================================================

init(_Args) -> {ok, undefined}.

handle_request(Payload, State) ->
    Caller = effective_caller(hecate_om_wire:caller(Payload), Payload),
    case learn(Payload, Caller) of
        {ok, Result} -> {reply, Result, State};
        {error, Reason} -> {error, Reason, State}
    end.

%% Phase 1.5 (mind-grained provenance, PLAN_MESH_TRUTHS_AND_PROVENANCE.md):
%% `hecate_om_wire:caller/1' is the WIRE-level identity -- whoever's
%% connection this RPC physically arrived on. A caller relaying the
%% call on behalf of someone else over a SHARED connection (hecate-
%% spartan making this call for one of its minds, all sharing spartan's
%% own mesh pool) can supply an `asserted_by' field instead: its own
%% Ed25519 identity plus a signature proving it, verified via
%% `hecate_om_ownership_proof' (requires hecate_om >= 0.23.0) the exact
%% same way hecate-citizens verifies a register_presence caller --
%% `{identity, timestamp, procedure}', procedure-bound so a proof minted
%% here can't be replayed against a different gated capability.
%%
%% A VALID `asserted_by' wins over the wire caller, not the other way
%% round -- the wire caller for a relayed call is always the relay's own
%% identity (spartan's, for every mind it relays on behalf of), so
%% "wire caller wins when present" would make asserted_by never actually
%% take effect for the one case it exists for. This is safe precisely
%% because forging a claim requires a valid signature for the claimed
%% identity: `hecate_om_ownership_proof:verify/3' rejects anything else,
%% so an absent or INVALID `asserted_by' falls back to the wire caller
%% (or to no caller at all) -- it can never impersonate a different
%% identity than the one whose key actually signed it. Both paths carry
%% the SAME confidence: a valid Ed25519 signature is equally
%% cryptographic proof of possession regardless of which of the two
%% mechanisms checked it.
effective_caller(WireCaller, Payload) ->
    asserted_or_wire(hecate_om_wire:field(asserted_by, Payload), WireCaller).

asserted_or_wire(AssertedBy, WireCaller) when is_map(AssertedBy) ->
    verified_or_wire(verify_asserted(AssertedBy), WireCaller);
asserted_or_wire(_Absent, WireCaller) ->
    WireCaller.

verified_or_wire({ok, Identity}, _WireCaller) -> Identity;
verified_or_wire({error, _Reason}, WireCaller) -> WireCaller.

verify_asserted(AssertedBy) ->
    verify_identity(hecate_om_ownership_proof:decode_identity(hecate_om_wire:field(identity, AssertedBy)),
                    hecate_om_wire:field(proof, AssertedBy, #{})).

verify_identity(undefined, _Proof) ->
    {error, invalid_identity};
verify_identity(Identity, Proof) ->
    verified(hecate_om_ownership_proof:verify(Identity, Proof, ?PROCEDURE), Identity).

verified(ok, Identity) -> {ok, Identity};
verified({error, _} = Error, _Identity) -> Error.

%%====================================================================
%% API
%%====================================================================

%% @equiv learn(Params, undefined)
-spec learn(map()) -> {ok, map()} | {error, term()}.
learn(Params) ->
    learn(Params, undefined).

%% RPC payloads decode with ATOM keys (macula_response's contract) --
%% but read via hecate_om_wire:field/2,3, never a hard #{key := V} match
%% in the head. Corpus Demon 60: a hard match on the wrong key shape
%% doesn't error, it silently falls through to the catch-all clause --
%% "missing_required_fields" for a call that supplied every field, the
%% believable-domain-error shape the corpus entry specifically warns
%% about, indistinguishable from a genuine caller mistake.
-spec learn(map(), binary() | undefined) -> {ok, map()} | {error, term()}.
learn(Params, Caller) when is_map(Params) ->
    learn_(hecate_om_wire:field(subject, Params),
           hecate_om_wire:field(predicate, Params),
           hecate_om_wire:field(object, Params),
           Params, Caller);
learn(_Params, _Caller) ->
    {error, missing_required_fields}.

learn_(undefined, _Predicate, _Object, _Params, _Caller) -> {error, missing_required_fields};
learn_(_Subject, undefined, _Object, _Params, _Caller) -> {error, missing_required_fields};
learn_(_Subject, _Predicate, undefined, _Params, _Caller) -> {error, missing_required_fields};
learn_(Subject, Predicate, Object, Params, Caller) ->
    Confidence = hecate_om_wire:field(confidence, Params, 1.0),
    Metadata = hecate_om_wire:field(metadata, Params, #{}),
    Now = erlang:system_time(millisecond),
    Source = hecate_graph_facts:reporter(),
    ensure_subject(Subject, Predicate, Object, Confidence, Metadata, Now, Source, Caller).

%%====================================================================
%% Internal — sequential fallible steps, one function per step so each
%% only ever nests one `case' deep (subject -> object -> link -> publish).
%%====================================================================

ensure_subject(Subject, Predicate, Object, Confidence, Metadata, Now, Source, Caller) ->
    case ensure_entity(Subject, Metadata, Now, Source) of
        {error, _} = Error ->
            Error;
        {ok, SubjectNew} ->
            ensure_object(Subject, Predicate, Object, Confidence, Metadata, Now, Source, SubjectNew, Caller)
    end.

ensure_object(Subject, Predicate, Object, Confidence, Metadata, Now, Source, SubjectNew, Caller) ->
    case ensure_entity(Object, Metadata, Now, Source) of
        {error, _} = Error ->
            Error;
        {ok, ObjectNew} ->
            write_link(Subject, Predicate, Object, Confidence, Now, Source, SubjectNew, ObjectNew, Caller)
    end.

write_link(Subject, Predicate, Object, Confidence, Now, Source, SubjectNew, ObjectNew, Caller) ->
    LinkId = link_id(Subject, Predicate, Object, Now),
    case insert_link(LinkId, Subject, Predicate, Object, Confidence, Source, Now) of
        {error, _} = Error ->
            Error;
        ok ->
            publish_link(Subject, Predicate, Object, Confidence, Source, Now),
            record_provenance(Caller, Subject, Object, Now, Source),
            {ok, #{link_id => LinkId, entities_new => SubjectNew + ObjectNew}}
    end.

%% Phase 1: the caller becomes a normal graph entity, asserted-linked to
%% both endpoints it just told the graph about -- "what has X ever told
%% the graph" becomes an ordinary resolve_link(X, direction=out,
%% predicate=asserted) traversal, not special-cased code. `undefined'
%% (older macula, or a payload that reached learn_link some way other
%% than a directly-authenticated RPC) just skips this -- best-effort,
%% not a reason to fail a write that already succeeded.
%%
%% Hex-encoded here, once, rather than stored as the raw 32-byte pubkey:
%% every other node identity in this workspace is displayed/queried as
%% hex (mesh_agents' node_id, FLEET.md's node-id column, and so on), and
%% a raw binary entity id would make `resolve_link(caller_entity, ...)'
%% -- the plan's own worked example -- unreachable from anything that
%% can't paste arbitrary bytes into a query.
record_provenance(undefined, _Subject, _Object, _Now, _Source) ->
    ok;
record_provenance(Caller, Subject, Object, Now, Source) ->
    CallerHex = binary:encode_hex(Caller, lowercase),
    case ensure_entity(CallerHex, #{}, Now, Source) of
        {error, Reason} ->
            logger:warning("learn_link: provenance entity for caller failed, "
                            "skipping asserted-links: ~p", [Reason]);
        {ok, _CallerNew} ->
            assert_link(CallerHex, Subject, Now, Source),
            assert_link(CallerHex, Object, Now, Source)
    end,
    ok.

assert_link(Caller, Target, Now, Source) ->
    LinkId = link_id(Caller, ?ASSERTED, Target, Now),
    case insert_link(LinkId, Caller, ?ASSERTED, Target, ?PROVENANCE_CONFIDENCE, Source, Now) of
        ok ->
            publish_link(Caller, ?ASSERTED, Target, ?PROVENANCE_CONFIDENCE, Source, Now);
        {error, Reason} ->
            logger:warning("learn_link: asserted-link ~s -> ~s failed: ~p",
                            [Caller, Target, Reason])
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
