-module(prop_algorithm_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% EUnit wrapper for PropEr
%%----------------------------------------------------------------------

proper_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"token_bucket never allows more than burst",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_token_bucket_respects_burst(), [
                        {numtests, 500}, {to_file, user}
                    ])
                )
            end}},
        {"sliding_window never allows more than limit",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_sliding_window_respects_limit(), [
                        {numtests, 500}, {to_file, user}
                    ])
                )
            end}},
        {"gcra never allows more than limit",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_gcra_respects_limit(), [{numtests, 500}, {to_file, user}])
                )
            end}},
        {"leaky_bucket never allows more than limit",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_leaky_bucket_respects_limit(), [
                        {numtests, 500}, {to_file, user}
                    ])
                )
            end}},
        {"all algorithms: allow returns non-negative remaining",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_allow_remaining_non_negative(), [
                        {numtests, 500}, {to_file, user}
                    ])
                )
            end}},
        {"all algorithms: deny returns positive retry_after",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_deny_retry_after_positive(), [
                        {numtests, 500}, {to_file, user}
                    ])
                )
            end}},
        {"all algorithms: inspect does not change state",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_inspect_idempotent(), [{numtests, 300}, {to_file, user}])
                )
            end}},
        {"all algorithms: reset restores capacity",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_reset_restores_capacity(), [
                        {numtests, 300}, {to_file, user}
                    ])
                )
            end}},
        {"all algorithms: different keys are independent",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_keys_independent(), [{numtests, 300}, {to_file, user}])
                )
            end}},
        {"codel enters dropping when latency sustained above target",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_codel_drops_on_sustained_latency(), [
                        {numtests, 200}, {to_file, user}
                    ])
                )
            end}},
        {"codel exits dropping when latency drops below target",
            {timeout, 60, fun() ->
                ?assert(
                    proper:quickcheck(prop_codel_recovers(), [{numtests, 200}, {to_file, user}])
                )
            end}}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

%%----------------------------------------------------------------------
%% Generators
%%----------------------------------------------------------------------

algorithm() ->
    oneof([token_bucket, sliding_window, gcra, leaky_bucket]).

limit() ->
    integer(1, 100).

window() ->
    integer(100, 10000).

num_requests() ->
    integer(1, 200).

%%----------------------------------------------------------------------
%% Properties: Rate Limiting Invariants
%%----------------------------------------------------------------------

%% Token bucket: total allowed requests at any instant <= burst
prop_token_bucket_respects_burst() ->
    ?FORALL(
        {Limit, Window, NumReqs},
        {limit(), window(), num_requests()},
        begin
            Name = make_limiter_name(),
            Burst = Limit,
            ok = seki:new_limiter(Name, #{
                algorithm => token_bucket,
                limit => Limit,
                window => Window,
                burst => Burst
            }),
            Allowed = count_allowed(Name, user1, NumReqs),
            seki:delete_limiter(Name),
            Allowed =< Burst
        end
    ).

%% Sliding window: instant burst cannot exceed limit
prop_sliding_window_respects_limit() ->
    ?FORALL(
        {Limit, Window, NumReqs},
        {limit(), window(), num_requests()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => sliding_window,
                limit => Limit,
                window => Window
            }),
            Allowed = count_allowed(Name, user1, NumReqs),
            seki:delete_limiter(Name),
            Allowed =< Limit
        end
    ).

%% GCRA: total allowed at any instant <= limit
prop_gcra_respects_limit() ->
    ?FORALL(
        {Limit, Window, NumReqs},
        {limit(), window(), num_requests()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => gcra,
                limit => Limit,
                window => Window
            }),
            Allowed = count_allowed(Name, user1, NumReqs),
            seki:delete_limiter(Name),
            Allowed =< Limit
        end
    ).

%% Leaky bucket: total allowed at any instant <= limit
prop_leaky_bucket_respects_limit() ->
    ?FORALL(
        {Limit, Window, NumReqs},
        {limit(), window(), num_requests()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => leaky_bucket,
                limit => Limit,
                window => Window
            }),
            Allowed = count_allowed(Name, user1, NumReqs),
            seki:delete_limiter(Name),
            Allowed =< Limit
        end
    ).

%% All algorithms: allow result has non-negative remaining
prop_allow_remaining_non_negative() ->
    ?FORALL(
        {Algo, Limit, Window},
        {algorithm(), limit(), window()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => Algo,
                limit => Limit,
                window => Window
            }),
            Result = seki:check(Name, user1),
            seki:delete_limiter(Name),
            case Result of
                {allow, #{remaining := R}} -> R >= 0;
                {deny, _} -> true
            end
        end
    ).

%% All algorithms: deny result has positive retry_after
prop_deny_retry_after_positive() ->
    ?FORALL(
        {Algo, Window},
        {algorithm(), window()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => Algo,
                limit => 1,
                window => Window
            }),
            %% First request should be allowed
            {allow, _} = seki:check(Name, user1),
            %% Second should be denied
            Result = seki:check(Name, user1),
            seki:delete_limiter(Name),
            case Result of
                {deny, #{retry_after := RA}} -> RA > 0;
                {allow, _} -> true
            end
        end
    ).

%% Inspect must not change observable state
prop_inspect_idempotent() ->
    ?FORALL(
        {Algo, Limit, Window},
        {algorithm(), limit(), window()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => Algo,
                limit => Limit,
                window => Window
            }),
            R1 = seki:inspect(Name, user1),
            R2 = seki:inspect(Name, user1),
            R3 = seki:inspect(Name, user1),
            seki:delete_limiter(Name),
            R1 =:= R2 andalso R2 =:= R3
        end
    ).

%% Reset restores capacity — after reset, should be able to make a request
prop_reset_restores_capacity() ->
    ?FORALL(
        {Algo, Window},
        {algorithm(), window()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => Algo,
                limit => 1,
                window => Window
            }),
            {allow, _} = seki:check(Name, user1),
            seki:reset(Name, user1),
            Result = seki:check(Name, user1),
            seki:delete_limiter(Name),
            case Result of
                {allow, _} -> true;
                {deny, _} -> false
            end
        end
    ).

%% Different keys must be independent
prop_keys_independent() ->
    ?FORALL(
        {Algo, Window},
        {algorithm(), window()},
        begin
            Name = make_limiter_name(),
            ok = seki:new_limiter(Name, #{
                algorithm => Algo,
                limit => 1,
                window => Window
            }),
            {allow, _} = seki:check(Name, key1),
            {deny, _} = seki:check(Name, key1),
            %% Different key should still be allowed
            Result = seki:check(Name, key2),
            seki:delete_limiter(Name),
            case Result of
                {allow, _} -> true;
                _ -> false
            end
        end
    ).

%%----------------------------------------------------------------------
%% Properties: CoDel
%%----------------------------------------------------------------------

%% CoDel should enter dropping mode when latency is sustained above target.
%% We use a small interval and sleep to ensure real wall time passes.
prop_codel_drops_on_sustained_latency() ->
    ?FORALL(
        {Target},
        {integer(1, 10)},
        begin
            Name = make_shed_name(),
            Interval = 10,
            {ok, _} = seki_shed:start_link(Name, #{
                target => Target,
                interval => Interval,
                max_in_flight => 10000
            }),
            HighLatency = Target + 50,
            %% Complete with high latency, sleeping to let wall time exceed interval
            lists:foreach(
                fun(_) ->
                    seki_shed:admit(Name),
                    seki_shed:complete(Name, HighLatency)
                end,
                lists:seq(1, 5)
            ),
            timer:sleep(Interval + 5),
            lists:foreach(
                fun(_) ->
                    seki_shed:admit(Name),
                    seki_shed:complete(Name, HighLatency)
                end,
                lists:seq(1, 10)
            ),
            #{dropping := Dropping} = seki_shed:status(Name),
            gen_server:stop(Name),
            Dropping =:= true
        end
    ).

%% CoDel should exit dropping mode when latency drops below target
prop_codel_recovers() ->
    ?FORALL(
        {Target},
        {integer(5, 20)},
        begin
            Name = make_shed_name(),
            Interval = 10,
            {ok, _} = seki_shed:start_link(Name, #{
                target => Target,
                interval => Interval,
                max_in_flight => 10000
            }),
            %% Push into dropping mode
            lists:foreach(
                fun(_) ->
                    seki_shed:admit(Name),
                    seki_shed:complete(Name, Target + 50)
                end,
                lists:seq(1, 5)
            ),
            timer:sleep(Interval + 5),
            lists:foreach(
                fun(_) ->
                    seki_shed:admit(Name),
                    seki_shed:complete(Name, Target + 50)
                end,
                lists:seq(1, 10)
            ),
            %% Now send good latencies
            lists:foreach(
                fun(_) ->
                    seki_shed:admit(Name),
                    seki_shed:complete(Name, 0)
                end,
                lists:seq(1, 20)
            ),
            #{dropping := Dropping} = seki_shed:status(Name),
            gen_server:stop(Name),
            Dropping =:= false
        end
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

count_allowed(Name, Key, N) ->
    lists:foldl(
        fun(_, Acc) ->
            case seki:check(Name, Key) of
                {allow, _} -> Acc + 1;
                {deny, _} -> Acc
            end
        end,
        0,
        lists:seq(1, N)
    ).

make_limiter_name() ->
    list_to_atom("prop_limiter_" ++ integer_to_list(erlang:unique_integer([positive]))).

make_shed_name() ->
    list_to_atom("prop_shed_" ++ integer_to_list(erlang:unique_integer([positive]))).
