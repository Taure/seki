# Architecture

How seki's processes are supervised, what a caller sees when one of them is
lost, and what is kept across a restart.

## Supervision Tree

```
seki_sup                          one_for_one, 5 restarts in 10 s
├── seki_registry_sup             rest_for_one
│   ├── seki_registry_keeper      holds the table of term names while the registry is down
│   └── seki_registry             owns the table and watches every process named by a term
├── seki_breaker_sup              one child for each breaker
│   └── seki_name_sup             temporary, 3 restarts in 10 s
│       └── seki_breaker          transient
├── seki_process_sup              one child for each bulkhead, adaptive limiter,
│   │                             load shedder and health checker
│   └── seki_name_sup             temporary, 3 restarts in 10 s
│       └── seki_bulkhead, seki_adaptive, seki_shed or seki_health
├── seki_scope_sup                the pg scopes seki started, 10 restarts in 60 s
│   └── pg scope                  seki_pg unless a limiter names another
├── seki_limiter_registry         holds every limiter and owns their tables
├── seki_gossip_sup               one child for each limiter on seki_backend_pg
│   └── seki_name_sup             temporary, 3 restarts in 10 s
│       └── seki_pg_gossip        transient
└── seki_ets_worker               one for each scheduler
```

`seki_sup` also owns the table that remembers which breakers are open
(`seki_breaker_trips`), so it outlives every breaker.

## One Supervisor for Each Name

Every breaker, bulkhead, adaptive limiter, load shedder and health checker has
a small supervisor of its own, `seki_name_sup`, with the process as its only
child. The supervisor the names share (`seki_breaker_sup` or
`seki_process_sup`) holds these small supervisors, not the processes, and
restarts nothing itself.

A process that crashes is restarted by its own supervisor, which tolerates 3
restarts in 10 seconds. On the fourth crash within 10 seconds it gives up and
stops. It is a temporary child, so the shared supervisor removes it and counts
no restart: a name that keeps crashing uses up only its own restarts, and
every other name keeps its process and its state. The intensity is fixed.

`seki:new_breaker/2` and the other `new_*` functions return the pid of the
process, not of its supervisor, and `seki:delete_breaker/1` and the other
`delete_*` functions stop the supervisor together with its process.

## When a Name Gives Up

Once the supervisor of a name has given up, the name is gone: seki treats it
as a name that was never created, until you create it again.

| Kind | Calls to a name that gave up | Created again |
|------|------------------------------|---------------|
| Breaker | `seki:call/2,3` and `seki:state/1` exit with `{noproc, _}`; the function is not run. `seki:reset_breaker/1` returns `ok` and does nothing. | Open if it was open when it was lost, for what is left of `wait_duration`; closed with an empty window otherwise. |
| Bulkhead | `call/2,3`, `acquire/1,2` and `status/1` exit with `{noproc, _}`. `release/1` returns `ok` and does nothing. | Empty: slots that were held are not counted. |
| Adaptive limiter | `call/2,3`, `acquire/1` and `status/1` exit with `{noproc, _}`. `release/2` returns `ok` and does nothing. | At its initial limit. |
| Load shedder | `admit/1,2` and `status/1` exit with `{noproc, _}`. `complete/2` returns `ok` and does nothing. | With no latency recorded. |
| Health checker | `check/1` and `readiness/1` exit with `{noproc, _}`. `liveness/1` returns `{error, unhealthy}`. | With no registered checks: register them again. |

Nothing is let through because a name is gone. `seki:new_breaker/2` and the
other `new_*` functions create the name again and return `{ok, Pid}`, and
`seki:delete_breaker/1` and the other `delete_*` functions return
`{error, not_found}` for it. A breaker that was open keeps its place in
`seki_breaker_trips` until it closes, is reset or is deleted, which is why it
comes back open.

The supervisor logs each crash and one `reached_max_restart_intensity` report
when it gives up. If you create names on demand (get or create), a name that
gave up is created again by the next request.

While a process is being restarted, which takes well under a millisecond, a
call to its name exits with `{noproc, _}` too, or with the reason the process
died for when the call was already waiting for its answer. A restarted process
starts as a new one does, with the same exceptions as above: an open breaker
is restarted open.

## What Is Kept

- **Names that are not atoms** are kept in one table, owned by `seki_registry`
  and inherited by `seki_registry_keeper` when the registry dies. If both are
  lost the table is made again from the processes the supervisors still hold.
  See [Unknown Names and a Stopped Application](getting-started.md#unknown-names-and-a-stopped-application).
- **Open breakers** are remembered outside the breaker, so a breaker never
  comes back more permissive than it was.
- **Limiters** live in `seki_limiter_registry`, which owns their tables. If
  that process dies, every limiter is lost and must be created again; until
  then `seki:check/2,3` raises `error:{limiter_not_found, Name}`, or
  `error:badarg` in the moment before the process is back. A custom
  backend runs its `init/1`, `cleanup/2` and `terminate/1` in that process: a
  failure in them is caught, but a process the backend links to it, or an
  `init/1` that does not return, is not contained (see `m:seki_backend`).
- **Gossip** for a limiter on `seki_backend_pg` runs in a process of its own
  that is not linked to the limiters. When it dies it is restarted on the
  same table and the limiter is not affected. After the fourth crash in 10
  seconds it is not restarted again: the limiter keeps counting on this node
  and stops sharing its state until it is deleted and created again. When its
  `pg` scope is restarted, the gossip process joins its group again. A scope
  the application started itself is never started by seki: the gossip process
  logs `gossip_scope_down` and looks every 100 ms until the application has
  started it again. A scope
  that crashes more than 10 times in 60 seconds takes the supervisor of the
  scopes with it; that supervisor is restarted empty, and each gossip process
  starts the scope it needs again, trying every 100 ms until it has joined.

While seki runs, a scope or a gossip process is only started under its
supervisor. In the moment one of those supervisors is itself being restarted,
`seki:new_limiter/2` for a limiter on `seki_backend_pg` returns
`{error, {backend_failed, _}}` and can be called again.

## Stopping

`application:stop(seki)` stops the supervisors in the reverse of the order
above. Each named process is given 5 seconds to stop; none of them traps
exits, so each stops at once and no supervisor report is logged. The `pg`
scopes that seki started stop with it. A scope that was already running when
a limiter first used it is not seki's to stop.
