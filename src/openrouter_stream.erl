-module(openrouter_stream).
%% @private
%% Internal SSE parser used by {@link openrouter_stream_worker}.

%% @doc Incremental SSE parser for streaming chat completions.
%%
%% Used internally by the stream worker. Feed raw SSE chunks via
%% {@link feed/2} and receive a list of typed events
%% (`content', `tool_call_delta', `finish', `done', `parse_error').
%%
%% For the public streaming API, use {@link openrouter:chat_stream/2}
%% which handles transport and delivers parsed events as messages.

-include("openrouter.hrl").

-export([new/0,
         feed/2,
         content/1,
         tool_calls/1,
         finish_reason/1,
         done/1]).

-export_type([state/0, event/0]).

-record(tc_acc, {
    id :: binary() | undefined,
    type = <<"function">> :: binary(),
    name :: binary() | undefined,
    arguments = <<>> :: binary()
}).

-record(stream_state, {
    buffer = <<>> :: binary(),      %% partial line from the socket
    content = <<>> :: binary(),     %% accumulated assistant text
    tool_calls = #{} :: #{integer() => #tc_acc{}},
    tc_order = [] :: [integer()],
    finish :: undefined | stop | length | tool_calls | content_filter | binary(),
    done = false :: boolean()
}).

-opaque state() :: #stream_state{}.

-type event() ::
      {content, binary()}
    | {tool_call_delta, integer()}
    | {finish, term()}
    | {parse_error, binary()}
    | done.

%% @doc Create a fresh stream parser state.
-spec new() -> state().
new() -> #stream_state{}.

%% @doc Feed a raw SSE binary chunk into the parser.
%%
%% Returns a list of events produced by this chunk and the updated state.
%% Partial lines are buffered internally until a newline arrives.
-spec feed(binary(), state()) -> {[event()], state()}.
feed(Chunk, #stream_state{buffer = Buf} = S0) when is_binary(Chunk) ->
    Combined = <<Buf/binary, Chunk/binary>>,
    {Lines, Rest} = split_lines(Combined),
    S1 = S0#stream_state{buffer = Rest},
    process_lines(Lines, S1, []).

%% @doc Return all content text accumulated so far.
-spec content(state()) -> binary().
content(#stream_state{content = C}) -> C.

%% @doc Return tool calls accumulated so far as `#tool_call{}' records.
%%
%% Merges incremental deltas by index internally; the returned list is
%% ordered by first appearance and does not expose wire-protocol indices.
-spec tool_calls(state()) -> [#tool_call{}].
tool_calls(#stream_state{tool_calls = Map, tc_order = Order}) ->
    [to_tool_call(maps:get(Idx, Map)) || Idx <- lists:reverse(Order)].

%% @doc Return the finish reason, or `undefined' if the stream has not finished.
-spec finish_reason(state()) -> undefined | atom() | binary().
finish_reason(#stream_state{finish = F}) -> F.

%% @doc Return whether the server has sent the `[DONE]' sentinel.
-spec done(state()) -> boolean().
done(#stream_state{done = D}) -> D.

split_lines(Bin) ->
    split_lines(Bin, 0, []).

split_lines(Bin, Offset, Acc) ->
    case binary:match(Bin, <<"\n">>, [{scope, {Offset, byte_size(Bin) - Offset}}]) of
        nomatch ->
            Tail = binary:part(Bin, Offset, byte_size(Bin) - Offset),
            {lists:reverse(Acc), Tail};
        {Pos, 1} ->
            Line = binary:part(Bin, Offset, Pos - Offset),
            Stripped = strip_cr(Line),
            split_lines(Bin, Pos + 1, [Stripped | Acc])
    end.

strip_cr(B) ->
    Sz = byte_size(B),
    case Sz > 0 andalso binary:at(B, Sz - 1) =:= $\r of
        true -> binary:part(B, 0, Sz - 1);
        false -> B
    end.

process_lines([], State, Events) ->
    {lists:reverse(Events), State};
process_lines([Line | Rest], State, Events) ->
    case classify_line(Line) of
        ignore ->
            process_lines(Rest, State, Events);
        {data, <<"[DONE]">>} ->
            process_lines(Rest, State#stream_state{done = true}, [done | Events]);
        {data, Payload} ->
            {NewEvents, State1} = handle_payload(Payload, State),
            process_lines(Rest, State1, prepend(NewEvents, Events))
    end.

prepend([], Acc) -> Acc;
prepend([H | T], Acc) -> prepend(T, [H | Acc]).

%% Classify a single SSE line. We accept `data: ...` lines and
%% ignore comments, event type lines, empty separators, and anything
%% else the spec permits. No catch-all beyond the structural cases.
classify_line(<<>>) -> ignore;
classify_line(<<":", _/binary>>) -> ignore;   %% SSE comment
classify_line(<<"event:", _/binary>>) -> ignore;
classify_line(<<"id:", _/binary>>) -> ignore;
classify_line(<<"retry:", _/binary>>) -> ignore;
classify_line(<<"data: ", Rest/binary>>) -> {data, Rest};
classify_line(<<"data:", Rest/binary>>) -> {data, Rest};
classify_line(_Other) -> ignore.

handle_payload(Payload, State) ->
    case openrouter_json:decode(Payload) of
        {ok, Map} when is_map(Map) ->
            Choices = maps:get(<<"choices">>, Map, []),
            handle_choices(Choices, State, []);
        {ok, _} ->
            {[{parse_error, Payload}], State};
        {error, _} ->
            {[{parse_error, Payload}], State}
    end.

handle_choices([], State, Events) ->
    {lists:reverse(Events), State};
handle_choices([Choice | Rest], State, Events) when is_map(Choice) ->
    Delta = maps:get(<<"delta">>, Choice, #{}),
    {ContentEvents, S1} = apply_content_delta(Delta, State),
    {ToolEvents, S2} = apply_tool_call_deltas(Delta, S1),
    {FinishEvents, S3} = apply_finish_reason(Choice, S2),
    handle_choices(Rest, S3,
                   ContentEvents ++ ToolEvents ++ FinishEvents ++ Events);
handle_choices([_ | Rest], State, Events) ->
    handle_choices(Rest, State, Events).

apply_content_delta(#{<<"content">> := Text}, State)
  when is_binary(Text), Text =/= <<>> ->
    S1 = State#stream_state{content = <<(State#stream_state.content)/binary,
                                        Text/binary>>},
    {[{content, Text}], S1};
apply_content_delta(_, State) ->
    {[], State}.

apply_tool_call_deltas(#{<<"tool_calls">> := List}, State) when is_list(List) ->
    lists:foldl(fun(D, {Evs, S}) ->
                        case merge_tool_call_delta(D, S) of
                            {ok, Idx, S1} ->
                                {[{tool_call_delta, Idx} | Evs], S1};
                            skip ->
                                {Evs, S}
                        end
                end, {[], State}, List);
apply_tool_call_deltas(_, State) ->
    {[], State}.

merge_tool_call_delta(Delta, State) when is_map(Delta) ->
    case maps:get(<<"index">>, Delta, undefined) of
        Idx when is_integer(Idx) ->
            Current = maps:get(Idx, State#stream_state.tool_calls,
                               #tc_acc{}),
            Updated = apply_delta_fields(Delta, Current),
            Map1 = maps:put(Idx, Updated, State#stream_state.tool_calls),
            Order1 = case lists:member(Idx, State#stream_state.tc_order) of
                         true -> State#stream_state.tc_order;
                         false -> [Idx | State#stream_state.tc_order]
                     end,
            {ok, Idx, State#stream_state{tool_calls = Map1,
                                         tc_order = Order1}};
        _ ->
            skip
    end.

apply_delta_fields(Delta, #tc_acc{} = Acc0) ->
    Acc1 = case maps:get(<<"id">>, Delta, undefined) of
               undefined -> Acc0;
               Id when is_binary(Id) -> Acc0#tc_acc{id = Id}
           end,
    Acc2 = case maps:get(<<"type">>, Delta, undefined) of
               undefined -> Acc1;
               Type when is_binary(Type) -> Acc1#tc_acc{type = Type}
           end,
    case maps:get(<<"function">>, Delta, undefined) of
        undefined -> Acc2;
        FnDelta when is_map(FnDelta) -> apply_fn_delta(FnDelta, Acc2)
    end.

apply_fn_delta(FnDelta, Acc0) ->
    Acc1 = case maps:get(<<"name">>, FnDelta, undefined) of
               undefined -> Acc0;
               Name when is_binary(Name) -> Acc0#tc_acc{name = Name}
           end,
    case maps:get(<<"arguments">>, FnDelta, undefined) of
        undefined -> Acc1;
        ArgDelta when is_binary(ArgDelta) ->
            Acc1#tc_acc{arguments = <<(Acc1#tc_acc.arguments)/binary,
                                       ArgDelta/binary>>}
    end.

apply_finish_reason(#{<<"finish_reason">> := Reason}, State)
  when Reason =/= null, Reason =/= undefined ->
    Atom = openrouter_chat:classify_finish_reason(Reason),
    {[{finish, Atom}], State#stream_state{finish = Atom}};
apply_finish_reason(_, State) ->
    {[], State}.

to_tool_call(#tc_acc{id = Id, type = T, name = N, arguments = A}) ->
    #tool_call{id = Id, type = T, function_name = N, function_arguments = A}.
