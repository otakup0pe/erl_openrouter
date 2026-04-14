-module(openrouter_chat).

-include("openrouter.hrl").

-export([build_request/2, parse_response/1]).
-export([classify_finish_reason/1]).

-spec build_request(Messages :: [map()], Opts :: map()) -> binary().
build_request(Messages, Opts) ->
    Base = #{<<"messages">> => Messages},
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
    WithStream = maybe_set(<<"stream">>, stream, Opts, WithFmt),
    WithTools = maybe_add_tools(Opts, WithStream),
    WithChoice = maybe_add_tool_choice(Opts, WithTools),
    {ok, Json} = openrouter_json:encode(WithChoice),
    Json.

-spec parse_response(Body :: binary()) -> {ok, #chat_response{}} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, Map} ->
            case validate_choices(maps:get(<<"choices">>, Map, [])) of
                ok ->
                    Response = #chat_response{
                        id = maps:get(<<"id">>, Map, undefined),
                        model = maps:get(<<"model">>, Map, undefined),
                        choices = maps:get(<<"choices">>, Map, []),
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

%% ---- Internal -------------------------------------------------------

maybe_set(JsonKey, OptKey, Opts, Map) ->
    case maps:get(OptKey, Opts, undefined) of
        undefined -> Map;
        Value -> Map#{JsonKey => Value}
    end.

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
