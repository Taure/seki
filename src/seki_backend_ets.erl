-module(seki_backend_ets).

-behaviour(seki_backend).

-export([
    init/1,
    get/2,
    put/3,
    update/4,
    delete/2,
    cleanup/2,
    terminate/1
]).

init(Opts) ->
    TableName = maps:get(table_name, Opts, seki_limiter_data),
    Tab = ets:new(TableName, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    {ok, Tab}.

get(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> not_found
    end.

put(Tab, Key, Value) ->
    true = ets:insert(Tab, {Key, Value}),
    ok.

update(Tab, Key, Fun, Default) ->
    NewValue =
        case ets:lookup(Tab, Key) of
            [{Key, Value}] -> Fun(Value);
            [] -> Fun(Default)
        end,
    true = ets:insert(Tab, {Key, NewValue}),
    {ok, NewValue}.

delete(Tab, Key) ->
    true = ets:delete(Tab, Key),
    ok.

cleanup(Tab, OlderThan) ->
    Now = erlang:monotonic_time(millisecond),
    Cutoff = Now - OlderThan,
    %% Delete entries where the timestamp component is older than cutoff
    %% Entries are stored as {Key, {State, Timestamp}} or similar
    ets:foldl(
        fun
            ({Key, {_, _, Ts}}, Acc) when Ts < Cutoff ->
                ets:delete(Tab, Key),
                Acc;
            ({Key, {_, Ts}}, Acc) when Ts < Cutoff ->
                ets:delete(Tab, Key),
                Acc;
            (_, Acc) ->
                Acc
        end,
        ok,
        Tab
    ),
    ok.

terminate(Tab) ->
    ets:delete(Tab),
    ok.
