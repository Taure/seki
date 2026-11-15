-module(seki_limiter_registry).
-moduledoc false.

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

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

-record(limiter, {
    name :: seki:name(),
    algorithm :: seki:algorithm(),
    backend :: module(),
    backend_state :: term(),
    config :: map()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(seki:name(), seki:limiter_opts()) -> ok | {error, term()}.
register(Pid, _Opts) when is_pid(Pid) ->
    {error, {invalid_name, Pid}};
register(Name, Opts) ->
    case gen_server:call(?MODULE, {register, Name, Opts}) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec unregister(seki:name()) -> ok.
unregister(Name) ->
    ok = gen_server:call(?MODULE, {unregister, Name}).

-spec lookup(seki:name()) -> {seki:algorithm(), module(), term(), map()}.
lookup(Name) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [
            #limiter{
                algorithm = Algorithm,
                backend = Backend,
                backend_state = BackendState,
                config = Config
            }
        ] ->
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
        {keypos, #limiter.name},
        {read_concurrency, true}
    ]),
    schedule_cleanup(),
    {ok, #{}}.

handle_call({register, Name, Opts}, _From, State) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [_] ->
            ?LOG_DEBUG(
                #{msg => limiter_already_registered, name => seki_name:label(Name)},
                #{domain => [seki]}
            ),
            {reply, {error, already_registered}, State};
        [] ->
            Backend = maps:get(backend, Opts, seki_backend_ets),
            case is_atomic(Backend) orelse maps:get(allow_non_atomic, Opts, false) of
                true ->
                    {reply, ok, start_limiter(Name, Backend, Opts, State)};
                false ->
                    {reply, {error, {backend_not_atomic, Backend}}, State}
            end
    end;
handle_call({unregister, Name}, _From, State) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [#limiter{backend = Backend, backend_state = BackendState}] ->
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
    _ = [
        Backend:terminate(BackendState)
     || #limiter{backend = Backend, backend_state = BackendState} <- ets:tab2list(?REGISTRY_TAB)
    ],
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

start_limiter(Name, Backend, Opts, State) ->
    Algorithm = maps:get(algorithm, Opts),
    BackendOpts = maps:merge(backend_defaults(Name), maps:get(backend_opts, Opts, #{})),
    Limiter = #{algorithm => Algorithm, window => maps:get(window, Opts)},
    {ok, BackendState} = Backend:init(BackendOpts#{seki_limiter => Limiter}),
    Config = (build_config(Algorithm, Opts))#{atomic => is_atomic(Backend)},
    true = ets:insert(?REGISTRY_TAB, #limiter{
        name = Name,
        algorithm = Algorithm,
        backend = Backend,
        backend_state = BackendState,
        config = Config
    }),
    State#{Name => BackendState}.

is_atomic(Backend) ->
    _ = code:ensure_loaded(Backend),
    erlang:function_exported(Backend, atomic_update, 3).

%% A table name is an atom, and making one from a term that is not would
%% create an atom per limiter. Such a limiter gets one shared label for its
%% (unnamed) table and is told apart by its `pg` group instead.
backend_defaults(Name) when is_atom(Name) ->
    #{table_name => list_to_atom("seki_limiter_" ++ atom_to_list(Name))};
backend_defaults(Name) ->
    #{table_name => seki_limiter, group => {seki_limiters, Name}}.

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
    _ = [
        Backend:cleanup(BackendState, ?CLEANUP_INTERVAL * 10)
     || #limiter{backend = Backend, backend_state = BackendState} <- ets:tab2list(?REGISTRY_TAB)
    ],
    ok.
