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
        {"tighter deadline wins", fun tighter_wins/0},
        {"to_header and from_header roundtrip", fun header_roundtrip/0},
        {"from_header with invalid value", fun invalid_header/0},
        {"retry respects deadline", fun retry_deadline/0},
        {"propagate to another process", fun propagate_test/0}
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

tighter_wins() ->
    seki_deadline:set(10000),
    seki_deadline:set(5000),
    Remaining = seki_deadline:time_remaining(),
    %% Should be close to 5000, not 10000
    ?assert(Remaining =< 5100),
    seki_deadline:clear().

header_roundtrip() ->
    seki_deadline:set(5000),
    {ok, Header} = seki_deadline:to_header(),
    ?assert(is_binary(Header)),
    seki_deadline:clear(),
    ok = seki_deadline:from_header(Header),
    Remaining = seki_deadline:time_remaining(),
    ?assert(Remaining > 0),
    seki_deadline:clear().

invalid_header() ->
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"not_a_number">>)),
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"0">>)),
    ?assertEqual({error, invalid_header}, seki_deadline:from_header(<<"-1">>)).

retry_deadline() ->
    %% Set a very short deadline
    seki_deadline:set(50),
    %% Retry with long delays — should abort due to deadline
    Result = seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 100,
        base_delay => 100,
        backoff => constant,
        jitter => none
    }),
    %% Should fail with deadline_exceeded, not exhaust all 100 attempts
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
