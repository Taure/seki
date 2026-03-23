-module(seki_limiter_registry).
-moduledoc false.

-behaviour(gen_server).

-export([
    start_link/0,
    register/2,
    unregister/1,
    lookup/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(REGISTRY_TAB, seki_limiter_registry).
-define(CLEANUP_INTERVAL, 60000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(atom(), seki:limiter_opts()) -> ok | {error, term()}.
register(Name, Opts) ->
    gen_server:call(?MODULE, {register, Name, Opts}).

-spec unregister(atom()) -> ok.
unregister(Name) ->
    gen_server:call(?MODULE, {unregister, Name}).

-spec lookup(atom()) -> {seki:algorithm(), module(), term(), map()}.
lookup(Name) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [{Name, Algorithm, Backend, BackendState, Config}] ->
            {Algorithm, Backend, BackendState, Config};
        [] ->
            error({limiter_not_found, Name})
    end.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init([]) ->
    _ = ets:new(?REGISTRY_TAB, [
        named_table,
        set,
        protected,
        {read_concurrency, true}
    ]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call({register, Name, Opts}, _From, State) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [_] ->
            logger:warning("Limiter ~p already registered", [Name], #{domain => [seki]}),
            {reply, {error, already_registered}, State};
        [] ->
            Algorithm = maps:get(algorithm, Opts),
            Backend = maps:get(backend, Opts, seki_backend_ets),
            BackendOpts = maps:get(backend_opts, Opts, #{table_name => limiter_table(Name)}),
            {ok, BackendState} = Backend:init(BackendOpts),
            Config = build_config(Algorithm, Opts),
            true = ets:insert(?REGISTRY_TAB, {Name, Algorithm, Backend, BackendState, Config}),
            {reply, ok, State#{Name => BackendState}}
    end;
handle_call({unregister, Name}, _From, State) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [{Name, _Algorithm, Backend, BackendState, _Config}] ->
            Backend:terminate(BackendState),
            ets:delete(?REGISTRY_TAB, Name),
            {reply, ok, maps:remove(Name, State)};
        [] ->
            {reply, ok, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    run_cleanup(),
    schedule_cleanup(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Clean up all backends
    ets:foldl(
        fun({_Name, _Alg, Backend, BackendState, _Config}, Acc) ->
            Backend:terminate(BackendState),
            Acc
        end,
        ok,
        ?REGISTRY_TAB
    ),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

limiter_table(Name) ->
    list_to_atom("seki_limiter_" ++ atom_to_list(Name)).

build_config(token_bucket, Opts) ->
    #{
        limit => maps:get(limit, Opts),
        window => maps:get(window, Opts),
        burst => maps:get(burst, Opts, maps:get(limit, Opts))
    };
build_config(sliding_window, Opts) ->
    #{
        limit => maps:get(limit, Opts),
        window => maps:get(window, Opts)
    };
build_config(gcra, Opts) ->
    Limit = maps:get(limit, Opts),
    Window = maps:get(window, Opts),
    Burst = maps:get(burst, Opts, Limit),
    EmissionInterval = Window / Limit,
    BurstTolerance = EmissionInterval * (Burst - 1),
    #{
        limit => Limit,
        window => Window,
        emission_interval => EmissionInterval,
        burst_tolerance => BurstTolerance
    };
build_config(leaky_bucket, Opts) ->
    #{
        limit => maps:get(limit, Opts),
        window => maps:get(window, Opts)
    }.

schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).

run_cleanup() ->
    ets:foldl(
        fun({_Name, _Alg, Backend, BackendState, _Config}, Acc) ->
            Backend:cleanup(BackendState, ?CLEANUP_INTERVAL * 10),
            Acc
        end,
        ok,
        ?REGISTRY_TAB
    ).
