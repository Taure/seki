-module(seki_bulkhead_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

bulkhead_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows calls within limit", fun allows_within_limit/0},
        {"rejects when full", fun rejects_when_full/0},
        {"releases on process exit", fun releases_on_exit/0},
        {"status reports correctly", fun status_reports/0},
        {"call wraps acquire/release", fun call_wraps/0}
    ]}.

allows_within_limit() ->
    {ok, _} = seki_bulkhead:start_link(bh_allow, #{max_concurrent => 3}),
    ?assertEqual(ok, seki_bulkhead:acquire(bh_allow)),
    ?assertEqual(ok, seki_bulkhead:acquire(bh_allow)),
    seki_bulkhead:release(bh_allow),
    seki_bulkhead:release(bh_allow),
    gen_server:stop(bh_allow).

rejects_when_full() ->
    {ok, _} = seki_bulkhead:start_link(bh_full, #{max_concurrent => 2}),
    ok = seki_bulkhead:acquire(bh_full),
    ok = seki_bulkhead:acquire(bh_full),
    ?assertEqual({error, bulkhead_full}, seki_bulkhead:acquire(bh_full)),
    seki_bulkhead:release(bh_full),
    %% Should be able to acquire again after release
    ?assertEqual(ok, seki_bulkhead:acquire(bh_full)),
    seki_bulkhead:release(bh_full),
    seki_bulkhead:release(bh_full),
    gen_server:stop(bh_full).

releases_on_exit() ->
    {ok, _} = seki_bulkhead:start_link(bh_exit, #{max_concurrent => 1}),
    Self = self(),
    Pid = spawn(fun() ->
        ok = seki_bulkhead:acquire(bh_exit),
        Self ! acquired,
        receive
            stop -> ok
        end
    end),
    receive
        acquired -> ok
    end,
    ?assertEqual({error, bulkhead_full}, seki_bulkhead:acquire(bh_exit)),
    %% Kill the holder
    exit(Pid, kill),
    timer:sleep(50),
    %% Should be released now
    ?assertEqual(ok, seki_bulkhead:acquire(bh_exit)),
    seki_bulkhead:release(bh_exit),
    gen_server:stop(bh_exit).

status_reports() ->
    {ok, _} = seki_bulkhead:start_link(bh_status, #{max_concurrent => 5}),
    ?assertEqual(#{current => 0, max => 5, available => 5}, seki_bulkhead:status(bh_status)),
    ok = seki_bulkhead:acquire(bh_status),
    ok = seki_bulkhead:acquire(bh_status),
    ?assertEqual(#{current => 2, max => 5, available => 3}, seki_bulkhead:status(bh_status)),
    seki_bulkhead:release(bh_status),
    seki_bulkhead:release(bh_status),
    gen_server:stop(bh_status).

call_wraps() ->
    {ok, _} = seki_bulkhead:start_link(bh_call, #{max_concurrent => 2}),
    ?assertEqual({ok, 42}, seki_bulkhead:call(bh_call, fun() -> 42 end)),
    %% Verify slot was released
    ?assertEqual(#{current => 0, max => 2, available => 2}, seki_bulkhead:status(bh_call)),
    gen_server:stop(bh_call).
