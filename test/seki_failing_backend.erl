-module(seki_failing_backend).

-behaviour(seki_backend).

%% A backend that raises in the callback named by `fails` in its options.

-export([init/1, get/2, put/3, update/4, atomic_update/3, delete/2, cleanup/2, terminate/1]).

init(#{fails := init}) -> error(init_failed);
init(#{fails := init_result}) -> not_ok;
init(#{fails := Callback} = Opts) -> {ok, {Callback, element(2, seki_backend_ets:init(Opts))}}.

get({_Fails, Tab}, Key) -> seki_backend_ets:get(Tab, Key).
put({_Fails, Tab}, Key, Value) -> seki_backend_ets:put(Tab, Key, Value).
update({_Fails, Tab}, Key, Fun, Default) -> seki_backend_ets:update(Tab, Key, Fun, Default).
atomic_update({_Fails, Tab}, Key, Step) -> seki_backend_ets:atomic_update(Tab, Key, Step).
delete({_Fails, Tab}, Key) -> seki_backend_ets:delete(Tab, Key).

cleanup({cleanup, _Tab}, _OlderThan) -> throw(cleanup_failed);
cleanup({_Fails, Tab}, OlderThan) -> seki_backend_ets:cleanup(Tab, OlderThan).

terminate({terminate, _Tab}) -> exit(terminate_failed);
terminate({_Fails, Tab}) -> seki_backend_ets:terminate(Tab).
