-module(seki_ets).
-moduledoc false.

-export([
    storage_key/1,
    lookup/2,
    insert/3,
    delete/2,
    atomic_update/3,
    atomic_update_stored/3,
    local_update/3,
    update/4,
    apply_update_fun/3,
    cleanup/2
]).

-define(MAX_ATTEMPTS, 1000).

-type current() :: not_found | {ok, term()}.
-type step() :: {module(), atom(), [term()]}.

-export_type([current/0, step/0]).

%% Keys are stored so they can sit in a match head as literals. A key that
%% would be read as a match variable, wildcard or partial map pattern is
%% stored as an escaped binary, and so is anything already shaped like one.
-spec storage_key(term()) -> term().
storage_key({seki_escaped_key, _} = Key) ->
    escape(Key);
storage_key(Key) ->
    case is_literal(Key) of
        true -> Key;
        false -> escape(Key)
    end.

-spec lookup(ets:table(), term()) -> {ok, term()} | not_found.
lookup(Tab, Key) ->
    case ets:lookup(Tab, storage_key(Key)) of
        [{_, Value}] -> {ok, Value};
        [] -> not_found
    end.

-spec insert(ets:table(), term(), term()) -> ok.
insert(Tab, Key, Value) ->
    true = ets:insert(Tab, {storage_key(Key), Value}),
    ok.

-spec delete(ets:table(), term()) -> ok.
delete(Tab, Key) ->
    true = ets:delete(Tab, storage_key(Key)),
    ok.

-spec atomic_update(ets:table(), term(), step()) -> {ok, term()} | {error, contention}.
atomic_update(Tab, Key, Step) ->
    atomic_update_stored(Tab, storage_key(Key), Step).

%% One compare-and-swap attempt in the caller. If another writer got there
%% first the key is contended, and the step moves to the worker that owns the
%% key, so contending callers queue instead of retrying against each other.
-spec atomic_update_stored(ets:table(), term(), step()) -> {ok, term()} | {error, contention}.
atomic_update_stored(Tab, StorageKey, Step) ->
    case attempt(Tab, StorageKey, Step) of
        {ok, Result} -> {ok, Result};
        conflict -> seki_ets_worker:atomic_update(Tab, StorageKey, Step)
    end.

-spec local_update(ets:table(), term(), step()) -> {ok, term()} | {error, contention}.
local_update(Tab, StorageKey, Step) ->
    local_update(Tab, StorageKey, Step, ?MAX_ATTEMPTS).

-spec update(ets:table(), term(), fun((term()) -> term()), term()) -> {ok, term()}.
update(Tab, Key, Fun, Default) when is_function(Fun, 1) ->
    case atomic_update(Tab, Key, {?MODULE, apply_update_fun, [Fun, Default]}) of
        {ok, NewValue} -> {ok, NewValue};
        {error, contention} -> error({contention, Key})
    end.

-spec apply_update_fun(current(), fun((term()) -> term()), term()) -> {term(), {write, term()}}.
apply_update_fun(not_found, Fun, Default) ->
    NewValue = Fun(Default),
    {NewValue, {write, NewValue}};
apply_update_fun({ok, Value}, Fun, _Default) ->
    NewValue = Fun(Value),
    {NewValue, {write, NewValue}}.

-spec cleanup(ets:table(), integer()) -> ok.
cleanup(Tab, OlderThan) ->
    Cutoff = erlang:monotonic_time(millisecond) - OlderThan,
    _ = ets:select_delete(Tab, [
        {{'_', {'_', '_', '$1'}}, [{'<', '$1', Cutoff}], [true]},
        {{'_', {'_', '$1'}}, [{'<', '$1', Cutoff}], [true]}
    ]),
    ok.

local_update(_Tab, _Key, _Step, 0) ->
    {error, contention};
local_update(Tab, Key, Step, Attempts) ->
    case attempt(Tab, Key, Step) of
        {ok, Result} -> {ok, Result};
        conflict -> local_update(Tab, Key, Step, Attempts - 1)
    end.

attempt(Tab, Key, {Module, Function, Args}) ->
    Current =
        case ets:lookup(Tab, Key) of
            [{_, Value}] -> {ok, Value};
            [] -> not_found
        end,
    case apply(Module, Function, [Current | Args]) of
        {Result, keep} ->
            {ok, Result};
        {Result, {write, NewValue}} ->
            case swap(Tab, Key, Current, NewValue) of
                true -> {ok, Result};
                false -> conflict
            end
    end.

swap(Tab, Key, not_found, NewValue) ->
    ets:insert_new(Tab, {Key, NewValue});
swap(Tab, Key, {ok, OldValue}, NewValue) ->
    ets:select_replace(Tab, swap_spec(Key, OldValue, NewValue)) =:= 1.

%% Storage keys are always literal, so the key goes in the match head and ETS
%% goes straight to the object. A value that would be read as a pattern is
%% compared in a guard instead.
swap_spec(StorageKey, OldValue, NewValue) ->
    Body = [{{{const, StorageKey}, {const, NewValue}}}],
    case is_literal(OldValue) of
        true -> [{{StorageKey, OldValue}, [], Body}];
        false -> [{{StorageKey, '$1'}, [{'=:=', '$1', {const, OldValue}}], Body}]
    end.

escape(Key) ->
    {seki_escaped_key, term_to_binary(Key, [deterministic])}.

is_literal('_') ->
    false;
is_literal(Term) when is_atom(Term) ->
    case atom_to_binary(Term) of
        <<"$", _/binary>> -> false;
        _ -> true
    end;
is_literal(Term) when is_tuple(Term) ->
    is_literal(tuple_to_list(Term));
is_literal([Head | Tail]) ->
    is_literal(Head) andalso is_literal(Tail);
is_literal(Term) when is_map(Term) ->
    false;
is_literal(_) ->
    true.
