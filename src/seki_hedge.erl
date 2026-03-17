-module(seki_hedge).

%% Request hedging — send redundant requests and use the first response.
%%
%% Reduces tail latency by racing multiple attempts. After a configurable
%% delay, a backup request is sent. The first response wins and the
%% other is cancelled.
%%
%% Inspired by Google's "The Tail at Scale" paper.

-export([
    race/2,
    race/3
]).

-type hedge_opts() :: #{
    delay => pos_integer(),
    max_extra => pos_integer()
}.

-export_type([hedge_opts/0]).

%% Race multiple invocations of Fun, returning the first successful result.
%% After `delay` ms, spawns a backup. At most `max_extra` backups are sent.
-spec race(fun(() -> term()), hedge_opts()) -> {ok, term()} | {error, all_failed}.
race(Fun, Opts) ->
    race(undefined, Fun, Opts).

-spec race(atom() | undefined, fun(() -> term()), hedge_opts()) ->
    {ok, term()} | {error, all_failed}.
race(Name, Fun, Opts) ->
    Delay = maps:get(delay, Opts, 100),
    MaxExtra = maps:get(max_extra, Opts, 1),
    Parent = self(),
    Ref = make_ref(),
    %% Start primary request
    Pid1 = spawn_monitor_fun(Fun, Parent, Ref),
    %% Wait for result or timeout
    Result = wait_or_hedge(Fun, Parent, Ref, Delay, MaxExtra, [Pid1], 0),
    emit_telemetry(Name, Result),
    Result.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

spawn_monitor_fun(Fun, Parent, Ref) ->
    spawn(fun() ->
        try
            Result = Fun(),
            Parent ! {hedge_result, Ref, self(), {ok, Result}}
        catch
            Class:Reason ->
                Parent ! {hedge_result, Ref, self(), {error, {Class, Reason}}}
        end
    end).

wait_or_hedge(Fun, Parent, Ref, Delay, MaxExtra, Pids, ExtraCount) ->
    receive
        {hedge_result, Ref, FromPid, {ok, Result}} ->
            %% Got a result — kill remaining
            kill_others(Pids, FromPid),
            {ok, Result};
        {hedge_result, Ref, FromPid, {error, _}} ->
            %% One attempt failed — wait for others if any
            RemainingPids = lists:delete(FromPid, Pids),
            case RemainingPids of
                [] ->
                    {error, all_failed};
                _ ->
                    wait_for_remaining(Ref, RemainingPids)
            end
    after Delay ->
        case ExtraCount < MaxExtra of
            true ->
                %% Spawn backup
                NewPid = spawn_monitor_fun(Fun, Parent, Ref),
                wait_or_hedge(
                    Fun, Parent, Ref, Delay, MaxExtra, [NewPid | Pids], ExtraCount + 1
                );
            false ->
                %% No more backups — just wait
                wait_for_remaining(Ref, Pids)
        end
    end.

wait_for_remaining(Ref, Pids) ->
    receive
        {hedge_result, Ref, FromPid, {ok, Result}} ->
            kill_others(Pids, FromPid),
            {ok, Result};
        {hedge_result, Ref, FromPid, {error, _}} ->
            RemainingPids = lists:delete(FromPid, Pids),
            case RemainingPids of
                [] -> {error, all_failed};
                _ -> wait_for_remaining(Ref, RemainingPids)
            end
    after 30000 ->
        lists:foreach(fun(P) -> exit(P, kill) end, Pids),
        {error, all_failed}
    end.

kill_others(Pids, WinnerPid) ->
    lists:foreach(
        fun(P) ->
            case P =:= WinnerPid of
                true -> ok;
                false -> exit(P, kill)
            end
        end,
        Pids
    ).

emit_telemetry(Name, Result) ->
    Status =
        case Result of
            {ok, _} -> ok;
            {error, _} -> error
        end,
    telemetry:execute(
        [seki, hedge, complete],
        #{count => 1},
        #{name => Name, status => Status}
    ).
