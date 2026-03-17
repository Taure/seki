-module(seki_deadline_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    seki_deadline:clear(),
    application:stop(seki),
    ok.

deadline_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"set and check within deadline", fun within_deadline/0},
        {"check after deadline expired", fun expired_deadline/0},
        {"time_remaining returns correct value", fun time_remaining/0},
        {"time_remaining returns infinity when no deadline", fun no_deadline/0},
        {"clear removes deadline", fun clear_deadline/0},
        {"run with deadline succeeds", fun run_succeeds/0},
        {"run clears deadline after", fun run_clears/0},
        {"run clears deadline on exception", fun run_clears_on_exception/0},
        {"run with expired deadline returns error", fun run_expired/0},
        {"tighter deadline wins", fun tighter_wins/0},
        {"looser deadline does not override", fun looser_no_override/0},
        {"to_header and from_header roundtrip", fun header_roundtrip/0},
        {"from_header with invalid value", fun invalid_header/0},
        {"from_header with non-binary", fun non_binary_header/0},
        {"to_header returns undefined with no deadline", fun to_header_no_deadline/0},
        {"retry respects deadline", fun retry_deadline/0},
        {"propagate to another process", fun propagate_test/0},
        {"propagate with no deadline is noop", fun propagate_no_deadline/0},
        {"reached returns boolean", fun reached_boolean/0},
        {"set_abs works directly", fun set_abs_direct/0},
        {"get returns {ok, Deadline} when set", fun get_returns_deadline/0},
        {"check returns ok with no deadline set", fun check_no_deadline/0}
    ]}.

within_deadline() ->
    seki_deadline:set(5000),
    ?assertEqual(ok, seki_deadline:check()),
    ?assertEqual(false, seki_deadline:reached()),
    seki_deadline:clear().

expired_deadline() ->
    seki_deadline:set(1),
    timer:sleep(10),
    ?assertEqual({error, deadline_exceeded}, seki_deadline:check()),
    ?assertEqual(true, seki_deadline:reached()),
    seki_deadline:clear().

time_remaining() ->
    seki_deadline:set(5000),
    Remaining = seki_deadline:time_remaining(),
    ?assert(Remaining > 0),
    ?assert(Remaining =< 5000),
    seki_deadline:clear().

no_deadline() ->
    seki_deadline:clear(),
    ?assertEqual(infinity, seki_deadline:time_remaining()),
    ?assertEqual(undefined, seki_deadline:get()).

clear_deadline() ->
    seki_deadline:set(5000),
    ?assertMatch({ok, _}, seki_deadline:get()),
    seki_deadline:clear(),
    ?assertEqual(undefined, seki_deadline:get()).

run_succeeds() ->
    Result = seki_deadline:run(5000, fun() -> hello end),
    ?assertEqual({ok, hello}, Result).

run_clears() ->
    seki_deadline:run(5000, fun() -> ok end),
    ?assertEqual(undefined, seki_deadline:get()).

run_clears_on_exception() ->
    try
        seki_deadline:run(5000, fun() -> error(boom) end)
    catch
        _:_ -> ok
    end,
    ?assertEqual(undefined, seki_deadline:get()).

run_expired() ->
    seki_deadline:set(1),
    timer:sleep(10),
    Result = seki_deadline:run(1, fun() -> should_not_run end),
    ?assertEqual({error, deadline_exceeded}, Result),
    seki_deadline:clear().

tighter_wins() ->
    seki_deadline:set(10000),
    seki_deadline:set(5000),
    Remaining = seki_deadline:time_remaining(),
    ?assert(Remaining =< 5100),
    seki_deadline:clear().

looser_no_override() ->
    seki_deadline:set(1000),
    seki_deadline:set(10000),
    Remaining = seki_deadline:time_remaining(),
    %% Should still be close to 1000, not 10000
    ?assert(Remaining =< 1100),
    seki_deadline:clear().

header_roundtrip() ->
    seki_deadline:set(5000),
    {ok, Header} = seki_deadline:to_header(),
    ?assert(is_binary(Header)),
    HeaderMs = binary_to_integer(Header),
    ?assert(HeaderMs > 0),
    ?assert(HeaderMs =< 5000),
    seki_deadline:clear(),
    ok = seki_deadline:from_header(Header),
    Remaining = seki_deadline:time_remaining(),
    ?assert(Remaining > 0),
    seki_deadline:clear().

invalid_header() ->
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"not_a_number">>)),
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"0">>)),
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"-1">>)).

non_binary_header() ->
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(123)),
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(not_binary)).

to_header_no_deadline() ->
    seki_deadline:clear(),
    ?assertEqual(undefined, seki_deadline:to_header()).

retry_deadline() ->
    seki_deadline:set(50),
    Result = seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 100,
        base_delay => 100,
        backoff => constant,
        jitter => none
    }),
    ?assertMatch({error, _}, Result),
    seki_deadline:clear().

propagate_test() ->
    seki_deadline:set(5000),
    Self = self(),
    Pid = spawn(fun() ->
        receive
            {seki_deadline_propagate, Deadline} ->
                seki_deadline:set_abs(Deadline),
                Remaining = seki_deadline:time_remaining(),
                Self ! {remaining, Remaining}
        end
    end),
    seki_deadline:propagate(Pid),
    receive
        {remaining, R} ->
            ?assert(R > 0),
            ?assert(R =< 5000)
    after 1000 ->
        ?assert(false)
    end,
    seki_deadline:clear().

propagate_no_deadline() ->
    seki_deadline:clear(),
    Pid = spawn(fun() ->
        receive
            _ -> ok
        after 100 -> ok
        end
    end),
    ?assertEqual(ok, seki_deadline:propagate(Pid)).

reached_boolean() ->
    seki_deadline:clear(),
    ?assertEqual(false, seki_deadline:reached()),
    seki_deadline:set(1),
    timer:sleep(10),
    ?assertEqual(true, seki_deadline:reached()),
    seki_deadline:clear().

set_abs_direct() ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    seki_deadline:set_abs(Deadline),
    ?assertMatch({ok, _}, seki_deadline:get()),
    Remaining = seki_deadline:time_remaining(),
    ?assert(Remaining > 0),
    ?assert(Remaining =< 5100),
    seki_deadline:clear().

get_returns_deadline() ->
    seki_deadline:set(5000),
    {ok, D} = seki_deadline:get(),
    ?assert(is_integer(D)),
    seki_deadline:clear().

check_no_deadline() ->
    seki_deadline:clear(),
    ?assertEqual(ok, seki_deadline:check()).
