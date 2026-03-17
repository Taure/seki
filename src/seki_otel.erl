-module(seki_otel).

-moduledoc """
OpenTelemetry instrumentation for Seki.

Subscribes to all Seki telemetry events and adds OTel span events with
`seki.*` attributes. Requires `opentelemetry` as a dependency.

Call `seki_otel:setup/0` in your application start callback.
""".

-export([
    setup/0,
    setup/1,
    teardown/0
]).

-export([
    handle_rate_limit/4,
    handle_breaker_state_change/4,
    handle_breaker_call/4,
    handle_retry/4,
    handle_bulkhead/4
]).

-define(HANDLER_ID_PREFIX, seki_otel).

-doc "Attach OTel handlers to all Seki telemetry events.".
-spec setup() -> ok.
setup() ->
    setup(#{}).

-doc "Attach OTel handlers with options.".
-spec setup(map()) -> ok.
setup(_Opts) ->
    Events = [
        {[seki, rate_limit, allow], fun ?MODULE:handle_rate_limit/4},
        {[seki, rate_limit, deny], fun ?MODULE:handle_rate_limit/4},
        {[seki, rate_limit, denied], fun ?MODULE:handle_rate_limit/4},
        {[seki, breaker, state_change], fun ?MODULE:handle_breaker_state_change/4},
        {[seki, breaker, call], fun ?MODULE:handle_breaker_call/4},
        {[seki, retry, attempt], fun ?MODULE:handle_retry/4},
        {[seki, retry, retry], fun ?MODULE:handle_retry/4},
        {[seki, retry, success], fun ?MODULE:handle_retry/4},
        {[seki, retry, exhausted], fun ?MODULE:handle_retry/4},
        {[seki, bulkhead, acquire], fun ?MODULE:handle_bulkhead/4},
        {[seki, bulkhead, release], fun ?MODULE:handle_bulkhead/4},
        {[seki, bulkhead, rejected], fun ?MODULE:handle_bulkhead/4}
    ],
    lists:foreach(
        fun({Event, Handler}) ->
            HandlerId = handler_id(Event),
            telemetry:attach(HandlerId, Event, Handler, #{})
        end,
        Events
    ),
    ok.

-doc "Detach all OTel handlers.".
-spec teardown() -> ok.
teardown() ->
    Events = [
        [seki, rate_limit, allow],
        [seki, rate_limit, deny],
        [seki, rate_limit, denied],
        [seki, breaker, state_change],
        [seki, breaker, call],
        [seki, retry, attempt],
        [seki, retry, retry],
        [seki, retry, success],
        [seki, retry, exhausted],
        [seki, bulkhead, acquire],
        [seki, bulkhead, release],
        [seki, bulkhead, rejected]
    ],
    lists:foreach(
        fun(Event) ->
            telemetry:detach(handler_id(Event))
        end,
        Events
    ),
    ok.

%%----------------------------------------------------------------------
%% Telemetry Handlers (exported for telemetry:attach)
%%----------------------------------------------------------------------

handle_rate_limit(Event, Measurements, Metadata, _Config) ->
    try
        otel_ctx:get_current(),
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = lists:last(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => rate_limit,
                    'seki.action' => Action,
                    'seki.name' => Name
                },
                AllAttrs = maps:merge(Attrs, measurements_to_attrs(Measurements)),
                otel_span:add_event(SpanCtx, <<"seki.rate_limit">>, AllAttrs)
        end
    catch
        _:OtelErr ->
            logger:debug(
                "seki_otel rate_limit handler failed: ~p",
                [OtelErr],
                #{domain => [seki]}
            )
    end.

handle_breaker_state_change(_Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Name = maps:get(name, Metadata, undefined),
                From = maps:get(from, Metadata, undefined),
                To = maps:get(to, Metadata, undefined),
                Attrs = #{
                    'seki.component' => circuit_breaker,
                    'seki.name' => Name,
                    'seki.breaker.from' => From,
                    'seki.breaker.to' => To
                },
                AllAttrs = maps:merge(Attrs, measurements_to_attrs(Measurements)),
                otel_span:add_event(SpanCtx, <<"seki.breaker.state_change">>, AllAttrs)
        end
    catch
        _:OtelErr2 ->
            logger:debug(
                "seki_otel breaker_state_change handler failed: ~p",
                [OtelErr2],
                #{domain => [seki]}
            )
    end.

handle_breaker_call(_Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Name = maps:get(name, Metadata, undefined),
                State = maps:get(state, Metadata, undefined),
                Outcome = maps:get(outcome, Metadata, undefined),
                Attrs = #{
                    'seki.component' => circuit_breaker,
                    'seki.name' => Name,
                    'seki.breaker.state' => State,
                    'seki.breaker.outcome' => Outcome,
                    'seki.breaker.duration_ms' => maps:get(duration, Measurements, 0)
                },
                otel_span:add_event(SpanCtx, <<"seki.breaker.call">>, Attrs)
        end
    catch
        _:OtelErr3 ->
            logger:debug(
                "seki_otel breaker_call handler failed: ~p",
                [OtelErr3],
                #{domain => [seki]}
            )
    end.

handle_retry(Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = lists:last(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => retry,
                    'seki.action' => Action,
                    'seki.name' => Name
                },
                AllAttrs = maps:merge(Attrs, measurements_to_attrs(Measurements)),
                otel_span:add_event(SpanCtx, <<"seki.retry">>, AllAttrs)
        end
    catch
        _:OtelErr4 ->
            logger:debug(
                "seki_otel retry handler failed: ~p",
                [OtelErr4],
                #{domain => [seki]}
            )
    end.

handle_bulkhead(Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = lists:last(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => bulkhead,
                    'seki.action' => Action,
                    'seki.name' => Name
                },
                AllAttrs = maps:merge(Attrs, measurements_to_attrs(Measurements)),
                otel_span:add_event(SpanCtx, <<"seki.bulkhead">>, AllAttrs)
        end
    catch
        _:OtelErr5 ->
            logger:debug(
                "seki_otel bulkhead handler failed: ~p",
                [OtelErr5],
                #{domain => [seki]}
            )
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

handler_id(Event) ->
    list_to_atom(
        lists:flatten(io_lib:format("~p_~s", [?HANDLER_ID_PREFIX, event_to_string(Event)]))
    ).

event_to_string(Event) ->
    string:join([atom_to_list(A) || A <- Event], "_").

measurements_to_attrs(Measurements) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = list_to_atom("seki." ++ atom_to_list(K)),
            Acc#{Key => V}
        end,
        #{},
        Measurements
    ).
