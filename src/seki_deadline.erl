-module(seki_deadline).

-moduledoc """
Deadline propagation for request processing.

Uses the process dictionary to carry deadlines through the call stack.
Multiple deadlines are merged by taking the tighter (earlier) one.
Integrates with `seki_retry` to stop retrying when time runs out.

For cross-service propagation, convert to/from HTTP headers using
`to_header/0` and `from_header/1`.

## Example

    seki_deadline:set(5000),  %% 5 second deadline
    ok = seki_deadline:check(),
    {ok, <<"3200">>} = seki_deadline:to_header().  %% remaining ms
""".

-export([
    set/1,
    set_abs/1,
    get/0,
    check/0,
    time_remaining/0,
    reached/0,
    clear/0,
    run/2,
    to_header/0,
    from_header/1,
    propagate/1
]).

-define(DEADLINE_KEY, seki_deadline).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc "Set a deadline relative to now (timeout in ms). Takes the tighter of existing and new deadlines.".
-spec set(pos_integer()) -> ok.
set(TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    set_abs(Deadline).

-doc "Set an absolute deadline (monotonic time in ms).".
-spec set_abs(integer()) -> ok.
set_abs(Deadline) ->
    case erlang:get(?DEADLINE_KEY) of
        undefined ->
            erlang:put(?DEADLINE_KEY, Deadline),
            ok;
        Existing ->
            %% Take the tighter (earlier) deadline
            erlang:put(?DEADLINE_KEY, min(Existing, Deadline)),
            ok
    end.

-doc "Get the current deadline, or `undefined` if none is set.".
-spec get() -> {ok, integer()} | undefined.
get() ->
    case erlang:get(?DEADLINE_KEY) of
        undefined -> undefined;
        Deadline -> {ok, Deadline}
    end.

-doc "Check if the deadline has been reached. Returns `ok` if there is still time or no deadline is set.".
-spec check() -> ok | {error, deadline_exceeded}.
check() ->
    case erlang:get(?DEADLINE_KEY) of
        undefined ->
            ok;
        Deadline ->
            Now = erlang:monotonic_time(millisecond),
            case Now < Deadline of
                true -> ok;
                false -> {error, deadline_exceeded}
            end
    end.

-doc "Get the remaining time in milliseconds, or `infinity` if no deadline is set.".
-spec time_remaining() -> non_neg_integer() | infinity.
time_remaining() ->
    case erlang:get(?DEADLINE_KEY) of
        undefined ->
            infinity;
        Deadline ->
            Now = erlang:monotonic_time(millisecond),
            max(0, Deadline - Now)
    end.

-doc "Check if the deadline has been reached (boolean).".
-spec reached() -> boolean().
reached() ->
    case check() of
        ok -> false;
        {error, deadline_exceeded} -> true
    end.

-doc "Clear the current deadline.".
-spec clear() -> ok.
clear() ->
    erlang:erase(?DEADLINE_KEY),
    ok.

-doc "Run a function with a deadline. Clears the deadline after completion.".
-spec run(pos_integer(), fun(() -> term())) ->
    {ok, term()} | {error, deadline_exceeded}.
run(TimeoutMs, Fun) ->
    set(TimeoutMs),
    try
        case check() of
            ok ->
                Result = Fun(),
                {ok, Result};
            {error, deadline_exceeded} = Error ->
                Error
        end
    after
        clear()
    end.

%%----------------------------------------------------------------------
%% Cross-service propagation via HTTP headers
%%----------------------------------------------------------------------

-doc "Convert current deadline to an HTTP header value (remaining ms as binary).".
-spec to_header() -> {ok, binary()} | undefined.
to_header() ->
    case time_remaining() of
        infinity -> undefined;
        Remaining -> {ok, integer_to_binary(Remaining)}
    end.

-doc "Set a deadline from an HTTP header value (remaining ms as binary).".
-spec from_header(binary()) -> ok | {error, invalid_header}.
from_header(Value) when is_binary(Value) ->
    try binary_to_integer(Value) of
        Ms when Ms > 0 ->
            set(Ms);
        _ ->
            {error, invalid_header}
    catch
        _:_ ->
            {error, invalid_header}
    end;
from_header(_) ->
    {error, invalid_header}.

-doc "Propagate the current deadline to another process via message passing.".
-spec propagate(pid()) -> ok.
propagate(TargetPid) ->
    case ?MODULE:get() of
        undefined ->
            ok;
        {ok, Deadline} ->
            erlang:send(TargetPid, {seki_deadline_propagate, Deadline}),
            ok
    end.
