-module(seki_backend).

%% Behaviour for rate limiter storage backends.
%%
%% Backends must support atomic read-modify-write operations
%% for rate limiting counters.

-callback init(Opts :: map()) -> {ok, State :: term()}.

-callback get(State :: term(), Key :: term()) -> {ok, Value :: term()} | not_found.

-callback put(State :: term(), Key :: term(), Value :: term()) -> ok.

-callback update(State :: term(), Key :: term(), Fun :: fun((term()) -> term()), Default :: term()) ->
    {ok, NewValue :: term()}.

-callback delete(State :: term(), Key :: term()) -> ok.

-callback cleanup(State :: term(), OlderThan :: integer()) -> ok.

-callback terminate(State :: term()) -> ok.
