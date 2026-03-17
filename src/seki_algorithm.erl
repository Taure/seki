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
    inspect/7
]).

-doc "Perform a rate limit check, consuming tokens/capacity. Called by `seki:check/3`.".
-doc #{since => <<"0.1.0">>}.

%%----------------------------------------------------------------------
%% Token Bucket
%%
%% Bucket fills at rate (limit/window) tokens per ms.
%% Allows bursts up to the burst capacity.
%% State: {Tokens :: float(), LastRefill :: integer()}
%%----------------------------------------------------------------------

check(token_bucket, Backend, State, Key, Cost, Now, Config) ->
    #{limit := _Limit, window := Window, burst := Burst} = Config,
    RefillRate = Burst / Window,
    case Backend:get(State, Key) of
        not_found ->
            NewTokens = Burst - Cost,
            case NewTokens >= 0 of
                true ->
                    Backend:put(State, Key, {NewTokens * 1.0, Now}),
                    {allow, #{remaining => NewTokens, reset => trunc(Cost / RefillRate)}};
                false ->
                    {deny, #{retry_after => trunc(Cost / RefillRate)}}
            end;
        {ok, {Tokens, LastRefill}} ->
            Elapsed = max(0, Now - LastRefill),
            Refilled = min(Burst * 1.0, Tokens + Elapsed * RefillRate),
            Remaining = Refilled - Cost,
            case Remaining >= 0 of
                true ->
                    Backend:put(State, Key, {Remaining, Now}),
                    ResetMs = trunc((Burst - Remaining) / RefillRate),
                    {allow, #{remaining => trunc(Remaining), reset => ResetMs}};
                false ->
                    %% Don't consume, just update refill time
                    Backend:put(State, Key, {Refilled, Now}),
                    DeficitMs = trunc((-Remaining) / RefillRate),
                    {deny, #{retry_after => max(1, DeficitMs)}}
            end
    end;
%%----------------------------------------------------------------------
%% Sliding Window Counter (Cloudflare-style)
%%
%% Uses two fixed windows and interpolates.
%% State: {PrevCount, CurrCount, WindowStart}
%%----------------------------------------------------------------------

check(sliding_window, Backend, State, Key, Cost, Now, Config) ->
    #{limit := Limit, window := Window} = Config,
    Default = {0, 0, window_start(Now, Window)},
    {ok, NewState} = Backend:update(
        State,
        Key,
        fun({PrevCount, CurrCount, WinStart}) ->
            case Now >= WinStart + Window of
                true ->
                    %% Rolled into new window
                    NewWinStart = window_start(Now, Window),
                    case Now >= WinStart + Window * 2 of
                        true ->
                            %% Previous window is also expired
                            {0, Cost, NewWinStart};
                        false ->
                            {CurrCount, Cost, NewWinStart}
                    end;
                false ->
                    {PrevCount, CurrCount + Cost, WinStart}
            end
        end,
        Default
    ),
    {PrevCount, CurrCount, WinStart} = NewState,
    Elapsed = Now - WinStart,
    Weight = max(0.0, (Window - Elapsed) / Window),
    EstimatedCount = PrevCount * Weight + CurrCount,
    case EstimatedCount =< Limit of
        true ->
            Remaining = max(0, trunc(Limit - EstimatedCount)),
            Reset = WinStart + Window - Now,
            {allow, #{remaining => Remaining, reset => Reset}};
        false ->
            %% Undo the cost we just added
            Backend:update(State, Key, fun({P, C, W}) -> {P, C - Cost, W} end, Default),
            RetryAfter = trunc((EstimatedCount - Limit) / (Limit / Window)) + 1,
            {deny, #{retry_after => RetryAfter}}
    end;
%%----------------------------------------------------------------------
%% GCRA (Generic Cell Rate Algorithm)
%%
%% Only stores one timestamp (TAT - Theoretical Arrival Time) per key.
%% State: TAT :: integer() (milliseconds)
%%----------------------------------------------------------------------

check(gcra, Backend, State, Key, Cost, Now, Config) ->
    #{emission_interval := T, burst_tolerance := Tau} = Config,
    Increment = T * Cost,
    case Backend:get(State, Key) of
        not_found ->
            NewTAT = Now + Increment,
            Backend:put(State, Key, NewTAT),
            #{limit := Limit} = Config,
            {allow, #{remaining => Limit - Cost, reset => Increment}};
        {ok, TAT} ->
            NewTAT = max(TAT, Now) + Increment,
            AllowAt = NewTAT - Tau - Increment,
            case Now >= AllowAt of
                true ->
                    Backend:put(State, Key, NewTAT),
                    Remaining = max(0, trunc((Tau + Increment - (NewTAT - Now)) / T)),
                    Reset = max(0, NewTAT - Now),
                    {allow, #{remaining => Remaining, reset => Reset}};
                false ->
                    RetryAfter = AllowAt - Now,
                    {deny, #{retry_after => RetryAfter}}
            end
    end;
%%----------------------------------------------------------------------
%% Leaky Bucket
%%
%% Queue drains at a fixed rate. No bursting.
%% State: {Level :: float(), LastDrain :: integer()}
%%----------------------------------------------------------------------

check(leaky_bucket, Backend, State, Key, Cost, Now, Config) ->
    #{limit := Limit, window := Window} = Config,
    DrainRate = Limit / Window,
    case Backend:get(State, Key) of
        not_found ->
            case Cost =< Limit of
                true ->
                    Backend:put(State, Key, {Cost * 1.0, Now}),
                    Remaining = Limit - Cost,
                    {allow, #{remaining => Remaining, reset => trunc(Cost / DrainRate)}};
                false ->
                    {deny, #{retry_after => trunc(Cost / DrainRate)}}
            end;
        {ok, {Level, LastDrain}} ->
            Elapsed = max(0, Now - LastDrain),
            Drained = max(0.0, Level - Elapsed * DrainRate),
            NewLevel = Drained + Cost,
            case NewLevel =< Limit of
                true ->
                    Backend:put(State, Key, {NewLevel, Now}),
                    Remaining = max(0, trunc(Limit - NewLevel)),
                    Reset = trunc(NewLevel / DrainRate),
                    {allow, #{remaining => Remaining, reset => Reset}};
                false ->
                    Backend:put(State, Key, {Drained, Now}),
                    Overflow = NewLevel - Limit,
                    RetryAfter = max(1, trunc(Overflow / DrainRate)),
                    {deny, #{retry_after => RetryAfter}}
            end
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
