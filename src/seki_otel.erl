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

-ifdef(TEST).
-export([name_attribute/1, measurements_to_attrs/1]).
-endif.

-doc "Attach OTel handlers to all Seki telemetry events.".
-spec setup() -> ok.
setup() ->
    setup(#{}).

-doc "Attach OTel handlers with options.".
-spec setup(map()) -> ok.
setup(_Opts) ->
    _ = [telemetry:attach(Id, Event, Handler, #{}) || {Id, Event, Handler} <- handlers()],
    ok.

-doc "Detach all OTel handlers.".
-spec teardown() -> ok.
teardown() ->
    _ = [telemetry:detach(Id) || {Id, _Event, _Handler} <- handlers()],
    ok.

%%----------------------------------------------------------------------
%% Telemetry Handlers (exported for telemetry:attach)
%%----------------------------------------------------------------------

-spec handle_rate_limit(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> term().
handle_rate_limit(Event, Measurements, Metadata, _Config) ->
    try
        otel_ctx:get_current(),
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = action(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => rate_limit,
                    'seki.action' => Action,
                    'seki.name' => name_attribute(Name)
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

-spec handle_breaker_state_change(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> term().
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
                    'seki.name' => name_attribute(Name),
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

-spec handle_breaker_call(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> term().
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
                    'seki.name' => name_attribute(Name),
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

-spec handle_retry(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> term().
handle_retry(Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = action(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => retry,
                    'seki.action' => Action,
                    'seki.name' => name_attribute(Name)
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

-spec handle_bulkhead(
    telemetry:event_name(),
    telemetry:event_measurements(),
    telemetry:event_metadata(),
    telemetry:handler_config()
) -> term().
handle_bulkhead(Event, Measurements, Metadata, _Config) ->
    try
        SpanCtx = otel_tracer:current_span_ctx(),
        case SpanCtx of
            undefined ->
                ok;
            _ ->
                Action = action(Event),
                Name = maps:get(name, Metadata, undefined),
                Attrs = #{
                    'seki.component' => bulkhead,
                    'seki.action' => Action,
                    'seki.name' => name_attribute(Name)
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

handlers() ->
    [
        {seki_otel_seki_rate_limit_allow, [seki, rate_limit, allow],
            fun ?MODULE:handle_rate_limit/4},
        {seki_otel_seki_rate_limit_deny, [seki, rate_limit, deny], fun ?MODULE:handle_rate_limit/4},
        {seki_otel_seki_rate_limit_denied, [seki, rate_limit, denied],
            fun ?MODULE:handle_rate_limit/4},
        {seki_otel_seki_breaker_state_change, [seki, breaker, state_change],
            fun ?MODULE:handle_breaker_state_change/4},
        {seki_otel_seki_breaker_call, [seki, breaker, call], fun ?MODULE:handle_breaker_call/4},
        {seki_otel_seki_retry_attempt, [seki, retry, attempt], fun ?MODULE:handle_retry/4},
        {seki_otel_seki_retry_retry, [seki, retry, retry], fun ?MODULE:handle_retry/4},
        {seki_otel_seki_retry_success, [seki, retry, success], fun ?MODULE:handle_retry/4},
        {seki_otel_seki_retry_exhausted, [seki, retry, exhausted], fun ?MODULE:handle_retry/4},
        {seki_otel_seki_bulkhead_acquire, [seki, bulkhead, acquire], fun ?MODULE:handle_bulkhead/4},
        {seki_otel_seki_bulkhead_release, [seki, bulkhead, release], fun ?MODULE:handle_bulkhead/4},
        {seki_otel_seki_bulkhead_rejected, [seki, bulkhead, rejected],
            fun ?MODULE:handle_bulkhead/4}
    ].

%% A span attribute is an atom, a binary or a number: a name that is some
%% other term is recorded as it prints, to a limited depth.
name_attribute(Name) -> seki_name:label(Name).

-spec action(telemetry:event_name()) -> atom().
action([Action]) -> Action;
action([_Segment | Rest]) -> action(Rest).

measurements_to_attrs(Measurements) ->
    #{attribute_key(Key) => Value || Key := Value <- Measurements}.

attribute_key(remaining) -> 'seki.remaining';
attribute_key(cost) -> 'seki.cost';
attribute_key(retry_after) -> 'seki.retry_after';
attribute_key(count) -> 'seki.count';
attribute_key(system_time) -> 'seki.system_time';
attribute_key(attempt) -> 'seki.attempt';
attribute_key(attempts) -> 'seki.attempts';
attribute_key(delay) -> 'seki.delay';
attribute_key(current) -> 'seki.current';
attribute_key(available) -> 'seki.available';
attribute_key(Key) -> <<"seki.", (atom_to_binary(Key))/binary>>.
