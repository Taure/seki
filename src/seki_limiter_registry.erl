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
-define(OPTION_KINDS, [
    {algorithm, {one_of, [token_bucket, sliding_window, gcra, leaky_bucket]}},
    {limit, pos_integer},
    {window, pos_integer},
    {burst, pos_integer},
    {backend, atom},
    {backend_opts, options},
    {allow_non_atomic, boolean}
]).

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
    case seki_options:check(Opts, ?OPTION_KINDS, [algorithm, limit, window]) of
        ok -> {reply, register_limiter(Name, Opts), State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({unregister, Name}, _From, State) ->
    case ets:lookup(?REGISTRY_TAB, Name) of
        [#limiter{} = Limiter] ->
            ok = backend_callback(Limiter, terminate, []),
            ets:delete(?REGISTRY_TAB, Name),
            {reply, ok, State};
        [] ->
            {reply, ok, State}
    end;
handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown_request}, State}.

handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

handle_info(cleanup, State) ->
    run_cleanup(),
    schedule_cleanup(),
    {noreply, State};
handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = [backend_callback(Limiter, terminate, []) || Limiter <- ets:tab2list(?REGISTRY_TAB)],
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

register_limiter(Name, Opts) ->
    Backend = maps:get(backend, Opts, seki_backend_ets),
    case ets:member(?REGISTRY_TAB, Name) of
        true ->
            ?LOG_DEBUG(
                #{msg => limiter_already_registered, name => seki_name:label(Name)},
                #{domain => [seki]}
            ),
            {error, already_registered};
        false ->
            case is_atomic(Backend) orelse maps:get(allow_non_atomic, Opts, false) of
                true -> start_limiter(Name, Backend, Opts);
                false -> {error, {backend_not_atomic, Backend}}
            end
    end.

%% The backend starts in this process, which holds every limiter, so a backend
%% that fails must not take the others with it.
start_limiter(Name, Backend, Opts) ->
    Algorithm = maps:get(algorithm, Opts),
    BackendOpts = maps:merge(backend_defaults(Name), maps:get(backend_opts, Opts, #{})),
    Limiter = #{algorithm => Algorithm, window => maps:get(window, Opts)},
    try Backend:init(BackendOpts#{seki_limiter => Limiter}) of
        {ok, BackendState} ->
            Config = (build_config(Algorithm, Opts))#{atomic => is_atomic(Backend)},
            true = ets:insert(?REGISTRY_TAB, #limiter{
                name = Name,
                algorithm = Algorithm,
                backend = Backend,
                backend_state = BackendState,
                config = Config
            }),
            ok;
        {error, Reason} ->
            {error, {backend_failed, Reason}};
        Other ->
            {error, {backend_failed, {bad_return, Other}}}
    catch
        Class:Reason ->
            {error, {backend_failed, {Class, Reason}}}
    end.

backend_callback(#limiter{name = Name, backend = Backend, backend_state = State}, Callback, Args) ->
    try
        _ = apply(Backend, Callback, [State | Args]),
        ok
    catch
        Class:Reason ->
            ?LOG_ERROR(
                #{
                    msg => limiter_backend_failed,
                    name => seki_name:label(Name),
                    backend => Backend,
                    callback => Callback,
                    class => Class,
                    reason => Reason
                },
                #{domain => [seki]}
            )
    end.

is_atomic(Backend) ->
    _ = code:ensure_loaded(Backend),
    erlang:function_exported(Backend, atomic_update, 3).

%% Every limiter labels its (unnamed) table alike and is told apart by its
%% `pg` group, which holds the name as it is: nothing is made into an atom.
backend_defaults(Name) ->
    #{table_name => seki_limiter, group => {seki_limiter, Name}}.

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
        backend_callback(Limiter, cleanup, [?CLEANUP_INTERVAL * 10])
     || Limiter <- ets:tab2list(?REGISTRY_TAB)
    ],
    ok.
