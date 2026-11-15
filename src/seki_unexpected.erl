-module(seki_unexpected).
-moduledoc false.

%% A seki process drops a message it has no use for. The first one each
%% process drops is logged, so a sender aimed at the wrong process shows up
%% without a line for every message. Only the tag of the message is logged:
%% what it holds is not seki's to print.

-include_lib("kernel/include/logger.hrl").

-export([dropped/3]).

-spec dropped(module(), call | cast | info, term()) -> ok.
dropped(Module, Kind, Message) ->
    case erlang:put(?MODULE, logged) of
        undefined ->
            ?LOG_WARNING(
                #{
                    msg => unexpected_message_dropped,
                    module => Module,
                    kind => Kind,
                    message => tag(Message)
                },
                #{domain => [seki]}
            );
        logged ->
            ok
    end,
    ok.

-spec tag(term()) -> atom().
tag(Message) when is_atom(Message) -> Message;
tag(Message) when is_tuple(Message), tuple_size(Message) > 0 -> tag_of(element(1, Message));
tag(_Message) -> other.

-spec tag_of(term()) -> atom().
tag_of(Tag) when is_atom(Tag) -> Tag;
tag_of(_NotAnAtom) -> other.
