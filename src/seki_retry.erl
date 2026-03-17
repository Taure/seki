-module(seki_retry).

%% Composable retry with backoff, jitter, and telemetry.

-export([
    run/2,
    run/3
]).

-type backoff() :: constant | exponential | linear.
-type jitter() :: none | full | equal | decorrelated.

-type retry_opts() :: #{
    max_attempts => pos_integer(),
    backoff => backoff(),
    base_delay => pos_integer(),
    max_delay => pos_integer(),
    jitter => jitter(),
    retry_on => fun((term()) -> boolean()),
    on_retry => fun((pos_integer(), term(), pos_integer()) -> ok)
}.

-export_type([backoff/0, jitter/0, retry_opts/0]).

-spec run(fun(() -> term()), retry_opts()) -> {ok, term()} | {error, term()}.
run(Fun, Opts) ->
    run(undefined, Fun, Opts).

-spec run(atom() | undefined, fun(() -> term()), retry_opts()) -> {ok, term()} | {error, term()}.
run(Name, Fun, Opts) ->
    MaxAttempts = maps:get(max_attempts, Opts, 3),
    RetryOn = maps:get(retry_on, Opts, fun default_retry_on/1),
    attempt(Name, Fun, Opts, RetryOn, 1, MaxAttempts, undefined).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

attempt(Name, _Fun, _Opts, _RetryOn, Attempt, MaxAttempts, LastError) when Attempt > MaxAttempts ->
    emit_exhausted(Name, MaxAttempts, LastError),
    {error, LastError};
attempt(Name, Fun, Opts, RetryOn, Attempt, MaxAttempts, _LastError) ->
    emit_attempt(Name, Attempt),
    try Fun() of
        Result ->
            case RetryOn(Result) of
                true when Attempt < MaxAttempts ->
                    Delay = compute_delay(Attempt, Opts),
                    emit_retry(Name, Attempt, Result, Delay, Opts),
                    timer:sleep(Delay),
                    attempt(Name, Fun, Opts, RetryOn, Attempt + 1, MaxAttempts, Result);
                true ->
                    emit_exhausted(Name, Attempt, Result),
                    {error, Result};
                false ->
                    emit_success(Name, Attempt),
                    {ok, Result}
            end
    catch
        Class:Reason:Stacktrace ->
            Error = {Class, Reason, Stacktrace},
            case RetryOn({error, Reason}) of
                true when Attempt < MaxAttempts ->
                    Delay = compute_delay(Attempt, Opts),
                    emit_retry(Name, Attempt, Error, Delay, Opts),
                    timer:sleep(Delay),
                    attempt(Name, Fun, Opts, RetryOn, Attempt + 1, MaxAttempts, Error);
                _ ->
                    emit_exhausted(Name, Attempt, Error),
                    {error, Error}
            end
    end.

default_retry_on({error, _}) -> true;
default_retry_on(_) -> false.

compute_delay(Attempt, Opts) ->
    Backoff = maps:get(backoff, Opts, exponential),
    BaseDelay = maps:get(base_delay, Opts, 100),
    MaxDelay = maps:get(max_delay, Opts, 30000),
    Jitter = maps:get(jitter, Opts, full),
    RawDelay = raw_delay(Backoff, BaseDelay, Attempt),
    Capped = min(RawDelay, MaxDelay),
    apply_jitter(Jitter, Capped, BaseDelay).

raw_delay(constant, BaseDelay, _Attempt) ->
    BaseDelay;
raw_delay(exponential, BaseDelay, Attempt) ->
    BaseDelay * (1 bsl (Attempt - 1));
raw_delay(linear, BaseDelay, Attempt) ->
    BaseDelay * Attempt.

apply_jitter(none, Delay, _Base) ->
    Delay;
apply_jitter(full, Delay, _Base) ->
    rand:uniform(max(1, Delay));
apply_jitter(equal, Delay, _Base) ->
    Half = max(1, Delay div 2),
    Half + rand:uniform(Half);
apply_jitter(decorrelated, Delay, Base) ->
    min(Delay, max(Base, rand:uniform(max(1, Delay * 3)))).

%%----------------------------------------------------------------------
%% Telemetry
%%----------------------------------------------------------------------

emit_attempt(Name, Attempt) ->
    telemetry:execute(
        [seki, retry, attempt],
        #{attempt => Attempt},
        #{name => Name}
    ).

emit_retry(Name, Attempt, Error, Delay, _Opts) ->
    OnRetry = maps:get(on_retry, _Opts, undefined),
    case OnRetry of
        undefined -> ok;
        Fun when is_function(Fun, 3) -> Fun(Attempt, Error, Delay)
    end,
    telemetry:execute(
        [seki, retry, retry],
        #{attempt => Attempt, delay => Delay},
        #{name => Name, error => Error}
    ).

emit_success(Name, Attempt) ->
    telemetry:execute(
        [seki, retry, success],
        #{attempt => Attempt},
        #{name => Name}
    ).

emit_exhausted(Name, Attempts, LastError) ->
    telemetry:execute(
        [seki, retry, exhausted],
        #{attempts => Attempts},
        #{name => Name, error => LastError}
    ).
