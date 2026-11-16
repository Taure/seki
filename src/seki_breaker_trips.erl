-module(seki_breaker_trips).
-moduledoc false.

%% When a breaker opens, the time it may next let a probe through is kept
%% here, outside the breaker. A breaker that is restarted, or created again
%% under the same name, starts open until that time, so it never comes back
%% more permissive than it was. The row goes when the breaker closes or is
%% deleted. `seki_sup` owns the table, which outlives every breaker and the
%% supervisor they share. A breaker started without the application has no
%% table and starts closed, as it always did.

-export([new_table/0, opened/2, closed/1, probe_at/1]).

-define(TAB, ?MODULE).

-spec new_table() -> ok.
new_table() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

-spec opened(seki:name(), integer()) -> ok.
opened(Name, ProbeAt) ->
    try ets:insert(?TAB, {Name, ProbeAt}) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec closed(seki:name()) -> ok.
closed(Name) ->
    try ets:delete(?TAB, Name) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec probe_at(seki:name()) -> integer() | closed.
probe_at(Name) ->
    try ets:lookup(?TAB, Name) of
        [{_Name, ProbeAt}] when is_integer(ProbeAt) -> ProbeAt;
        _Closed -> closed
    catch
        error:badarg -> closed
    end.
