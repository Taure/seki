-module(seki_unexpected_tests).

-include_lib("eunit/include/eunit.hrl").

-export([dropped_by/3, dropped_by/2, log/2]).

-define(HANDLER, seki_unexpected_tests).

%% What every seki process is held to: an unexpected message, cast or call
%% changes nothing, the call is refused, and one warning is logged however
%% many arrive.
-spec dropped_by(pid() | atom(), module(), term()) -> ok.
dropped_by(Server, Module, Refusal) ->
    ?assertEqual(
        [#{msg => unexpected_message_dropped, module => Module, kind => info, message => stray}],
        dropped_by(Server, Refusal)
    ).

-spec dropped_by(pid() | atom(), term()) -> [map()].
dropped_by(Name, Refusal) when is_atom(Name) ->
    case whereis(Name) of
        Server when is_pid(Server) -> dropped_by(Server, Refusal)
    end;
dropped_by(Server, Refusal) ->
    Before = sys:get_state(Server),
    ok = logger:add_handler(?HANDLER, ?MODULE, #{level => warning, config => #{pid => self()}}),
    try
        Server ! {stray, info},
        ok = gen_server:cast(Server, {stray, cast}),
        ?assertEqual(Refusal, gen_server:call(Server, {stray, call})),
        Server ! stray,
        ?assertEqual(Before, sys:get_state(Server)),
        ?assert(is_process_alive(Server)),
        logged_by(Server)
    after
        ok = logger:remove_handler(?HANDLER)
    end.

log(#{msg := {report, Report}, meta := #{pid := From}}, #{config := #{pid := Pid}}) ->
    Pid ! {logged, From, Report},
    ok;
log(_Event, _Config) ->
    ok.

logged_by(Server) ->
    receive
        {logged, Server, #{msg := unexpected_message_dropped} = Report} ->
            [Report | logged_by(Server)]
    after 0 -> []
    end.

the_first_drop_of_a_process_is_logged_test() ->
    ok = logger:add_handler(?HANDLER, ?MODULE, #{level => warning, config => #{pid => self()}}),
    try
        {First, FirstMonitor} = spawn_monitor(fun() ->
            ok = seki_unexpected:dropped(a_module, call, {a, tuple}),
            ok = seki_unexpected:dropped(a_module, cast, an_atom),
            ok = seki_unexpected:dropped(a_module, info, ~"a binary")
        end),
        {Second, SecondMonitor} = spawn_monitor(fun() ->
            ok = seki_unexpected:dropped(another, cast, {~"not an atom", 1}),
            ok = seki_unexpected:dropped(another, info, {})
        end),
        [
            receive
                {'DOWN', Monitor, process, _, Reason} -> ?assertEqual(normal, Reason)
            end
         || Monitor <:- [FirstMonitor, SecondMonitor]
        ],
        ?assertEqual(
            [#{msg => unexpected_message_dropped, module => a_module, kind => call, message => a}],
            logged_by(First)
        ),
        ?assertEqual(
            [
                #{
                    msg => unexpected_message_dropped,
                    module => another,
                    kind => cast,
                    message => other
                }
            ],
            logged_by(Second)
        )
    after
        ok = logger:remove_handler(?HANDLER)
    end.

what_is_logged_of_a_message_test() ->
    Logged = fun(Message) ->
        ok = logger:add_handler(?HANDLER, ?MODULE, #{
            level => warning, config => #{pid => self()}
        }),
        {Pid, Monitor} = spawn_monitor(fun() ->
            ok = seki_unexpected:dropped(a_module, info, Message)
        end),
        receive
            {'DOWN', Monitor, process, Pid, normal} -> ok
        end,
        ok = logger:remove_handler(?HANDLER),
        [#{message := Shape}] = logged_by(Pid),
        Shape
    end,
    ?assertEqual(timeout, Logged(timeout)),
    ?assertEqual('DOWN', Logged({'DOWN', make_ref(), process, self(), normal})),
    ?assertEqual(other, Logged({})),
    ?assertEqual(other, Logged({~"secret", 1})),
    ?assertEqual(other, Logged(~"secret")),
    ?assertEqual(other, Logged([secret])),
    ?assertEqual(other, Logged(#{secret => 1})).

a_drop_below_the_log_level_is_not_formatted_test() ->
    Level = maps:get(level, logger:get_primary_config()),
    ok = logger:set_primary_config(level, error),
    try
        ?assertEqual(ok, seki_unexpected:dropped(a_module, info, stray))
    after
        ok = logger:set_primary_config(level, Level)
    end.
