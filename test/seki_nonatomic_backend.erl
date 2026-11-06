-module(seki_nonatomic_backend).

-behaviour(seki_backend).

-export([init/1, get/2, put/3, update/4, delete/2, cleanup/2, terminate/1]).

init(Opts) -> seki_backend_ets:init(Opts).
get(Tab, Key) -> seki_backend_ets:get(Tab, Key).
put(Tab, Key, Value) -> seki_backend_ets:put(Tab, Key, Value).
update(Tab, Key, Fun, Default) -> seki_backend_ets:update(Tab, Key, Fun, Default).
delete(Tab, Key) -> seki_backend_ets:delete(Tab, Key).
cleanup(Tab, OlderThan) -> seki_backend_ets:cleanup(Tab, OlderThan).
terminate(Tab) -> seki_backend_ets:terminate(Tab).
