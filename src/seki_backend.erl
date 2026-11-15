-module(seki_backend).

-moduledoc """
Behaviour for rate limiter storage backends.

Implement this behaviour to provide custom storage (e.g., Redis, Mnesia).
Backends must support atomic read-modify-write operations for rate limiting counters.

Two built-in implementations: `seki_backend_ets` (local) and `seki_backend_pg` (distributed).

## Atomic checks

`seki:check/3` runs each check through the optional `atomic_update/3`
callback. `Step` is `{Module, Function, Args}`: the backend reads the current
value of `Key` and calls `apply(Module, Function, [Current | Args])`, where
`Current` is `not_found` or `{ok, Value}`. The step returns `{Result, keep}`
or `{Result, {write, NewValue}}`. The write must only land if `Key` still holds
the value the step saw; otherwise the backend reads again and re-applies the
step. Steps are pure, so running one more than once is safe. Return
`{ok, Result}`, or `{error, contention}` after giving up, which `seki:check/3`
turns into a deny.

`seki:new_limiter/2` refuses a backend that does not export `atomic_update/3`
with `{error, {backend_not_atomic, Backend}}`, unless the limiter is created
with `allow_non_atomic => true`. Such a limiter checks with `get/2` then
`put/3`, which is not atomic: concurrent checks of one key can then let more
requests through than the limit allows.

`update/4` must be atomic too, and may call `Fun` more than once.

## Failures

`init/1` runs in the process that holds every limiter. When it returns
`{error, Reason}`, raises, or returns anything else, `seki:new_limiter/2`
returns `{error, {backend_failed, _}}` and no limiter is created. A failure
in `cleanup/2` or `terminate/1` is logged and the other limiters carry on.
Do not link a process to the caller of `init/1` unless its death should take
every limiter with it.
""".

-callback init(Opts :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.

-callback get(State :: term(), Key :: term()) -> {ok, Value :: term()} | not_found.

-callback put(State :: term(), Key :: term(), Value :: term()) -> ok.

-callback update(State :: term(), Key :: term(), Fun :: fun((term()) -> term()), Default :: term()) ->
    {ok, NewValue :: term()}.

-callback atomic_update(State :: term(), Key :: term(), Step :: {module(), atom(), [term()]}) ->
    {ok, Result :: term()} | {error, contention}.

-callback delete(State :: term(), Key :: term()) -> ok.

-callback cleanup(State :: term(), OlderThan :: integer()) -> ok.

-callback terminate(State :: term()) -> ok.

-optional_callbacks([atomic_update/3]).
