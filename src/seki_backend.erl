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

## Cleanup

Once a minute seki calls `cleanup/2` for every limiter, to delete the state
of keys that have not been seen for `OlderThan` milliseconds: ten minutes, or
twice the window of the limiter when that is longer, so a key is never
forgotten while it still counts against the limit.

The state of a key of a `gcra` limiter is one number, the time the key is free
again in `erlang:monotonic_time(millisecond)`, and carries no time it was last
seen. For such a limiter seki also calls the optional `cleanup_arrivals/1`,
which deletes every key whose time has passed. A backend without it keeps one
value for every key a `gcra` limiter has ever seen.

## Failures

`init/1` runs in the process that holds every limiter. When it returns
`{error, Reason}`, raises, or returns anything else, `seki:new_limiter/2`
returns `{error, {backend_failed, _}}` and no limiter is created. A failure
in `cleanup/2`, `cleanup_arrivals/1` or `terminate/1` is logged and the other limiters carry on.

Two things a backend can do in `init/1` are not contained. A process it links
to the caller takes every limiter with it when it dies: supervise such a
process elsewhere, as `seki_backend_pg` does its gossip process. And an
`init/1` that does not return holds up every later `seki:new_limiter/2` and
`seki:delete_limiter/1`, which exit with a timeout after 5 seconds; checks
against the limiters that exist are not held up.
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

-callback cleanup_arrivals(State :: term()) -> ok.

-callback terminate(State :: term()) -> ok.

-optional_callbacks([atomic_update/3, cleanup_arrivals/1]).
