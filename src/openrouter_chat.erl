-module(openrouter_chat).

-include("openrouter.hrl").

-export([build_request/2, parse_response/1]).

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
    WithTools = maybe_set(<<"tools">>, tools, Opts, WithFmt),
    WithChoice = maybe_set(<<"tool_choice">>, tool_choice, Opts, WithTools),
    {ok, Json} = openrouter_json:encode(WithChoice),
    Json.

-spec parse_response(Body :: binary()) -> {ok, #chat_response{}} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, Map} ->
            Response = #chat_response{
                id = maps:get(<<"id">>, Map, undefined),
                model = maps:get(<<"model">>, Map, undefined),
                choices = maps:get(<<"choices">>, Map, []),
                usage = maps:get(<<"usage">>, Map, #{}),
                cost = maps:get(<<"cost">>, Map, undefined)
            },
            {ok, Response};
        {error, Reason} ->
            {error, {parse_error, Reason}}
    end.

maybe_set(JsonKey, OptKey, Opts, Map) ->
    case maps:get(OptKey, Opts, undefined) of
        undefined -> Map;
        Value -> Map#{JsonKey => Value}
    end.
