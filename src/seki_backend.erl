-module(seki_backend).

-moduledoc """
Behaviour for rate limiter storage backends.

Implement this behaviour to provide custom storage (e.g., Redis, Mnesia).
Backends must support atomic read-modify-write operations for rate limiting counters.

Two built-in implementations: `seki_backend_ets` (local) and `seki_backend_pg` (distributed).
""".

-callback init(Opts :: map()) -> {ok, State :: term()}.

-callback get(State :: term(), Key :: term()) -> {ok, Value :: term()} | not_found.

-callback put(State :: term(), Key :: term(), Value :: term()) -> ok.

-callback update(State :: term(), Key :: term(), Fun :: fun((term()) -> term()), Default :: term()) ->
    {ok, NewValue :: term()}.

-callback delete(State :: term(), Key :: term()) -> ok.

-callback cleanup(State :: term(), OlderThan :: integer()) -> ok.

-callback terminate(State :: term()) -> ok.
