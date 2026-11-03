-module(seki_algorithm).

-moduledoc """
Rate limiting algorithm implementations.

Four algorithms with different trade-offs:

| Algorithm | Burst | State size | Best for |
|-----------|-------|-----------|----------|
| `token_bucket` | Yes | 2 values | APIs allowing bursts |
| `sliding_window` | No | 3 values | General purpose |
| `gcra` | Configurable | 1 value | High-performance, minimal state |
| `leaky_bucket` | No | 2 values | Traffic shaping |

Not called directly — used internally by `seki` via the limiter registry.
""".

-export([
    check/7,
    step/5,
    inspect/7
]).

-doc """
Perform a rate limit check, consuming tokens/capacity. Called by `seki:check/3`.

The read, decision and write happen as one atomic step when the backend
exports `atomic_update/3`. If the backend gives up under contention the check
is denied.
""".
-doc #{since => <<"0.1.0">>}.
check(Algorithm, Backend, State, Key, Cost, Now, Config) ->
    StepArgs = [Algorithm, Cost, Now, Config],
    case erlang:function_exported(Backend, atomic_update, 3) of
        true ->
            case Backend:atomic_update(State, Key, {?MODULE, step, StepArgs}) of
                {ok, Result} -> Result;
                {error, contention} -> {deny, #{retry_after => 1}}
            end;
        false ->
            {Result, Write} = step(Backend:get(State, Key), Algorithm, Cost, Now, Config),
            ok = write(Backend, State, Key, Write),
            Result
    end.

-doc false.

%%----------------------------------------------------------------------
%% Token Bucket
%%
%% Bucket fills at rate (limit/window) tokens per ms.
%% Allows bursts up to the burst capacity.
%% State: {Tokens :: float(), LastRefill :: integer()}
%%----------------------------------------------------------------------

step(not_found, token_bucket, Cost, Now, #{window := Window, burst := Burst}) ->
    RefillRate = Burst / Window,
    NewTokens = Burst - Cost,
    case NewTokens >= 0 of
        true ->
            {
                {allow, #{remaining => NewTokens, reset => trunc(Cost / RefillRate)}},
                {write, {NewTokens * 1.0, Now}}
            };
        false ->
            {{deny, #{retry_after => trunc(Cost / RefillRate)}}, keep}
    end;
step({ok, {Tokens, LastRefill}}, token_bucket, Cost, Now, #{window := Window, burst := Burst}) ->
    RefillRate = Burst / Window,
    Elapsed = max(0, Now - LastRefill),
    Refilled = min(Burst * 1.0, Tokens + Elapsed * RefillRate),
    Remaining = Refilled - Cost,
    case Remaining >= 0 of
        true ->
            ResetMs = trunc((Burst - Remaining) / RefillRate),
            {
                {allow, #{remaining => trunc(Remaining), reset => ResetMs}},
                {write, {Remaining, Now}}
            };
        false ->
            DeficitMs = trunc((-Remaining) / RefillRate),
            {{deny, #{retry_after => max(1, DeficitMs)}}, {write, {Refilled, Now}}}
    end;
%%----------------------------------------------------------------------
%% Sliding Window Counter (Cloudflare-style)
%%
%% Uses two fixed windows and interpolates.
%% State: {PrevCount, CurrCount, WindowStart}
%%----------------------------------------------------------------------

step(Current, sliding_window, Cost, Now, #{limit := Limit, window := Window}) ->
    {PrevCount, CurrCount, WinStart} = Rolled = roll_window(Current, Now, Window),
    Weight = max(0.0, (Window - (Now - WinStart)) / Window),
    EstimatedCount = PrevCount * Weight + CurrCount + Cost,
    case EstimatedCount =< Limit of
        true ->
            Remaining = max(0, trunc(Limit - EstimatedCount)),
            Reset = WinStart + Window - Now,
            {
                {allow, #{remaining => Remaining, reset => Reset}},
                {write, {PrevCount, CurrCount + Cost, WinStart}}
            };
        false ->
            RetryAfter = trunc((EstimatedCount - Limit) / (Limit / Window)) + 1,
            {{deny, #{retry_after => RetryAfter}}, write_if_rolled(Current, Rolled)}
    end;
%%----------------------------------------------------------------------
%% GCRA (Generic Cell Rate Algorithm)
%%
%% Only stores one timestamp (TAT - Theoretical Arrival Time) per key.
%% State: TAT :: number() (milliseconds)
%%----------------------------------------------------------------------

step(not_found, gcra, Cost, Now, #{emission_interval := T, limit := Limit}) ->
    Increment = T * Cost,
    {{allow, #{remaining => Limit - Cost, reset => Increment}}, {write, Now + Increment}};
step({ok, TAT}, gcra, Cost, Now, #{emission_interval := T, burst_tolerance := Tau}) ->
    Increment = T * Cost,
    NewTAT = max(TAT, Now) + Increment,
    AllowAt = NewTAT - Tau - Increment,
    case Now >= AllowAt of
        true ->
            Remaining = max(0, trunc((Tau + Increment - (NewTAT - Now)) / T)),
            Reset = max(0, NewTAT - Now),
            {{allow, #{remaining => Remaining, reset => Reset}}, {write, NewTAT}};
        false ->
            {{deny, #{retry_after => AllowAt - Now}}, keep}
    end;
%%----------------------------------------------------------------------
%% Leaky Bucket
%%
%% Queue drains at a fixed rate. No bursting.
%% State: {Level :: float(), LastDrain :: integer()}
%%----------------------------------------------------------------------

step(not_found, leaky_bucket, Cost, Now, #{limit := Limit, window := Window}) ->
    DrainRate = Limit / Window,
    case Cost =< Limit of
        true ->
            {
                {allow, #{remaining => Limit - Cost, reset => trunc(Cost / DrainRate)}},
                {write, {Cost * 1.0, Now}}
            };
        false ->
            {{deny, #{retry_after => trunc(Cost / DrainRate)}}, keep}
    end;
step({ok, {Level, LastDrain}}, leaky_bucket, Cost, Now, #{limit := Limit, window := Window}) ->
    DrainRate = Limit / Window,
    Elapsed = max(0, Now - LastDrain),
    Drained = max(0.0, Level - Elapsed * DrainRate),
    NewLevel = Drained + Cost,
    case NewLevel =< Limit of
        true ->
            Remaining = max(0, trunc(Limit - NewLevel)),
            Reset = trunc(NewLevel / DrainRate),
            {{allow, #{remaining => Remaining, reset => Reset}}, {write, {NewLevel, Now}}};
        false ->
            Overflow = NewLevel - Limit,
            RetryAfter = max(1, trunc(Overflow / DrainRate)),
            {{deny, #{retry_after => RetryAfter}}, {write, {Drained, Now}}}
    end.

%%----------------------------------------------------------------------
%% Inspect (read-only, no side effects)
%%----------------------------------------------------------------------

-doc "Non-destructive rate limit check — reads state without consuming. Called by `seki:inspect/3`.".
inspect(token_bucket, Backend, State, Key, Cost, Now, Config) ->
    #{limit := _Limit, window := Window, burst := Burst} = Config,
    RefillRate = Burst / Window,
    case Backend:get(State, Key) of
        not_found ->
            {allow, #{remaining => Burst, reset => 0}};
        {ok, {Tokens, LastRefill}} ->
            Elapsed = max(0, Now - LastRefill),
            Refilled = min(Burst * 1.0, Tokens + Elapsed * RefillRate),
            case Refilled >= Cost of
                true ->
                    {allow, #{remaining => trunc(Refilled), reset => 0}};
                false ->
                    DeficitMs = max(1, trunc((Cost - Refilled) / RefillRate)),
                    {deny, #{retry_after => DeficitMs}}
            end
    end;
inspect(sliding_window, Backend, State, Key, Cost, Now, Config) ->
    #{limit := Limit, window := Window} = Config,
    case Backend:get(State, Key) of
        not_found ->
            {allow, #{remaining => Limit, reset => 0}};
        {ok, {PrevCount, CurrCount, WinStart}} ->
            Elapsed = Now - WinStart,
            Weight = max(0.0, (Window - Elapsed) / Window),
            EstimatedCount = PrevCount * Weight + CurrCount + Cost,
            case EstimatedCount =< Limit of
                true ->
                    {allow, #{
                        remaining => max(0, trunc(Limit - EstimatedCount)),
                        reset => WinStart + Window - Now
                    }};
                false ->
                    RetryAfter = trunc((EstimatedCount - Limit) / (Limit / Window)) + 1,
                    {deny, #{retry_after => RetryAfter}}
            end
    end;
inspect(gcra, Backend, State, Key, Cost, Now, Config) ->
    #{emission_interval := T, burst_tolerance := Tau} = Config,
    Increment = T * Cost,
    case Backend:get(State, Key) of
        not_found ->
            #{limit := Limit} = Config,
            {allow, #{remaining => Limit, reset => 0}};
        {ok, TAT} ->
            NewTAT = max(TAT, Now) + Increment,
            AllowAt = NewTAT - Tau - Increment,
            case Now >= AllowAt of
                true ->
                    Remaining = max(0, trunc((Tau + Increment - (NewTAT - Now)) / T)),
                    {allow, #{remaining => Remaining, reset => max(0, NewTAT - Now)}};
                false ->
                    {deny, #{retry_after => AllowAt - Now}}
            end
    end;
inspect(leaky_bucket, Backend, State, Key, Cost, Now, Config) ->
    #{limit := Limit, window := Window} = Config,
    DrainRate = Limit / Window,
    case Backend:get(State, Key) of
        not_found ->
            {allow, #{remaining => Limit, reset => 0}};
        {ok, {Level, LastDrain}} ->
            Elapsed = max(0, Now - LastDrain),
            Drained = max(0.0, Level - Elapsed * DrainRate),
            case Drained + Cost =< Limit of
                true ->
                    {allow, #{
                        remaining => max(0, trunc(Limit - Drained - Cost)),
                        reset => trunc(Drained / DrainRate)
                    }};
                false ->
                    Overflow = Drained + Cost - Limit,
                    {deny, #{retry_after => trunc(Overflow / DrainRate) + 1}}
            end
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

window_start(Now, Window) ->
    Now - (Now rem Window).

roll_window(not_found, Now, Window) ->
    {0, 0, window_start(Now, Window)};
roll_window({ok, {_PrevCount, _CurrCount, WinStart}}, Now, Window) when
    Now >= WinStart + Window * 2
->
    {0, 0, window_start(Now, Window)};
roll_window({ok, {_PrevCount, CurrCount, WinStart}}, Now, Window) when Now >= WinStart + Window ->
    {CurrCount, 0, window_start(Now, Window)};
roll_window({ok, Counts}, _Now, _Window) ->
    Counts.

write_if_rolled({ok, Rolled}, Rolled) ->
    keep;
write_if_rolled(not_found, _Rolled) ->
    keep;
write_if_rolled(_Current, Rolled) ->
    {write, Rolled}.

write(_Backend, _State, _Key, keep) ->
    ok;
write(Backend, State, Key, {write, Value}) ->
    Backend:put(State, Key, Value).
