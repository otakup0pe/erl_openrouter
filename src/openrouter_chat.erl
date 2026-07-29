-module(openrouter_chat).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

-include("openrouter.hrl").

-export([build_request/2, parse_response/1]).
-export([classify_finish_reason/1]).
-export([extract_text_content/1]).

-spec build_request(Messages :: [map()], Opts :: map()) -> binary().
build_request(Messages, Opts) ->
    SafeMessages = openrouter_text:sanitize_messages(Messages),
    Base = #{<<"messages">> => SafeMessages},
    WithModel = maybe_set(<<"model">>, model, Opts, Base),
    WithTemp = maybe_set(<<"temperature">>, temperature, Opts, WithModel),
    WithTopP = maybe_set(<<"top_p">>, top_p, Opts, WithTemp),
    WithTopK = maybe_set(<<"top_k">>, top_k, Opts, WithTopP),
    WithFreq = maybe_set(<<"frequency_penalty">>, frequency_penalty, Opts, WithTopK),
    WithPres = maybe_set(<<"presence_penalty">>, presence_penalty, Opts, WithFreq),
    WithRep = maybe_set(<<"repetition_penalty">>, repetition_penalty, Opts, WithPres),
    WithMinP = maybe_set(<<"min_p">>, min_p, Opts, WithRep),
    WithTopA = maybe_set(<<"top_a">>, top_a, Opts, WithMinP),
    WithSeed = maybe_set(<<"seed">>, seed, Opts, WithTopA),
    WithMax = maybe_set(<<"max_tokens">>, max_tokens, Opts, WithSeed),
    WithStop = maybe_set(<<"stop">>, stop, Opts, WithMax),
    WithFmt = maybe_set(<<"response_format">>, response_format, Opts, WithStop),
    WithStream = guard_stream_opt(maybe_set(<<"stream">>, stream, Opts, WithFmt)),
    WithTools = maybe_add_tools(Opts, WithStream),
    WithChoice = maybe_add_tool_choice(Opts, WithTools),
    WithProvider = maybe_set(<<"provider">>, provider, Opts, WithChoice),
    {ok, Json} = openrouter_json:encode(WithProvider),
    Json.

-spec parse_response(Body :: binary()) ->
    {ok, #chat_response{}} |
    {error, #api_error{} |
            {parse_error, {parse_error, badarg | {term(), term()} | {term(), term(), term()}}}}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, Map} ->
            RawChoices = maps:get(<<"choices">>, Map, []),
            case validate_choices(RawChoices) of
                ok ->
                    Choices = normalize_choices_content(RawChoices),
                    Response = #chat_response{
                        id = maps:get(<<"id">>, Map, undefined),
                        model = maps:get(<<"model">>, Map, undefined),
                        choices = Choices,
                        usage = maps:get(<<"usage">>, Map, #{}),
                        cost = maps:get(<<"cost">>, Map, undefined)
                    },
                    {ok, Response};
                {error, _} = Err ->
                    Err
            end;
        {error, Reason} ->
            {error, {parse_error, Reason}}
    end.

-spec classify_finish_reason(binary() | undefined) ->
    undefined | stop | length | tool_calls | content_filter | binary().
classify_finish_reason(undefined) -> undefined;
classify_finish_reason(<<"stop">>) -> stop;
classify_finish_reason(<<"length">>) -> length;
classify_finish_reason(<<"tool_calls">>) -> tool_calls;
classify_finish_reason(<<"content_filter">>) -> content_filter;
classify_finish_reason(Other) when is_binary(Other) -> Other.

%% @doc Extract text content from a chat response choice message.
%% Handles three content formats:
%%   - Binary: plain text content (standard)
%%   - List: content blocks (extended thinking models return
%%     [{type: "thinking", ...}, {type: "text", text: "..."}])
%%   - null: content is absent, check reasoning_content fallback
%%
%% Returns the text content as a binary, or null if no text found.
-spec extract_text_content(map()) -> binary() | null.
extract_text_content(#{<<"message">> := Msg}) ->
    normalize_message_content(Msg);
extract_text_content(_) ->
    null.

%% ---- Internal -------------------------------------------------------

%% Normalize content in all choices so downstream consumers always
%% see a binary or null in message.content, never a content blocks list.
normalize_choices_content(Choices) ->
    [normalize_choice_content(C) || C <- Choices].

normalize_choice_content(#{<<"message">> := Msg} = Choice) ->
    Choice#{<<"message">> => normalize_message(Msg)};
normalize_choice_content(Choice) ->
    Choice.

normalize_message(Msg) ->
    Content = normalize_message_content(Msg),
    Msg#{<<"content">> => Content}.

normalize_message_content(Msg) ->
    case maps:get(<<"content">>, Msg, null) of
        Bin when is_binary(Bin) ->
            Bin;
        Blocks when is_list(Blocks) ->
            %% Content blocks format from extended thinking models.
            %% Extract the text block(s), concatenate if multiple.
            extract_text_from_blocks(Blocks);
        null ->
            %% null or missing -- check reasoning_content fallback
            %% (some providers surface response text here for thinking models)
            case maps:get(<<"reasoning_content">>, Msg, undefined) of
                RC when is_binary(RC), RC =/= <<>> -> RC;
                undefined -> null;
                null -> null;
                <<>> -> null
            end
    end.

extract_text_from_blocks([]) -> null;
extract_text_from_blocks(Blocks) ->
    Texts = [T || #{<<"type">> := <<"text">>, <<"text">> := T} <- Blocks,
                  is_binary(T)],
    case Texts of
        [] -> null;
        [Single] -> Single;
        Multiple -> iolist_to_binary(lists:join(<<"\n">>, Multiple))
    end.

guard_stream_opt(#{<<"stream">> := true}) ->
    erlang:error({stream_not_supported,
                  <<"Streaming requires openrouter:chat_stream/2, not openrouter:chat/2">>});
guard_stream_opt(Map) ->
    Map.

maybe_set(JsonKey, OptKey, Opts, Map) ->
    openrouter_json:maybe_set(JsonKey, OptKey, Opts, Map).

maybe_add_tools(Opts, Map) ->
    case maps:get(tools, Opts, undefined) of
        undefined -> Map;
        [] -> Map;
        Tools when is_list(Tools) ->
            case openrouter_tools:validate_tools(Tools) of
                ok ->
                    Map#{<<"tools">> => openrouter_tools:encode_tools(Tools)};
                {error, Reason} ->
                    erlang:error(Reason)
            end
    end.

maybe_add_tool_choice(Opts, Map) ->
    case maps:get(tool_choice, Opts, undefined) of
        undefined -> Map;
        Choice ->
            case openrouter_tools:encode_tool_choice(Choice) of
                undefined -> Map;
                Encoded -> Map#{<<"tool_choice">> => Encoded}
            end
    end.

%% When the model chose to call tools, the response choice MUST
%% carry a tool_calls array. Missing it is a malformed response;
%% surface it rather than silently returning an empty list.
validate_choices([]) -> ok;
validate_choices(Choices) when is_list(Choices) ->
    validate_choices_1(Choices).

validate_choices_1([]) -> ok;
validate_choices_1([Choice | Rest]) when is_map(Choice) ->
    Reason = maps:get(<<"finish_reason">>, Choice, undefined),
    case Reason of
        <<"tool_calls">> ->
            Msg = maps:get(<<"message">>, Choice, #{}),
            case maps:get(<<"tool_calls">>, Msg, undefined) of
                undefined ->
                    {error, #api_error{
                        type = malformed_response,
                        message = <<"finish_reason=tool_calls but message.tool_calls missing">>,
                        metadata = #{reason => {malformed_response, missing_tool_calls}}
                    }};
                _ -> validate_choices_1(Rest)
            end;
        _ -> validate_choices_1(Rest)
    end;
validate_choices_1([_ | Rest]) ->
    validate_choices_1(Rest).
