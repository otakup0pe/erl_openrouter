-module(openrouter_error).

-include("openrouter.hrl").

-export([classify/1, classify/2, from_body/1]).

-spec classify(Reason :: term()) -> #api_error{}.
classify(timeout) ->
    #api_error{type = timeout, message = <<"Request timed out">>, metadata = #{}};
classify({failed_connect, _} = Reason) ->
    #api_error{type = timeout, message = iolist_to_binary(io_lib:format("~p", [Reason])),
               metadata = #{}};
classify(Reason) ->
    #api_error{type = server_error, message = iolist_to_binary(io_lib:format("~p", [Reason])),
               metadata = #{}}.

-spec classify(StatusCode :: integer(), Body :: binary()) -> #api_error{}.
classify(StatusCode, Body) ->
    BaseError = status_to_error(StatusCode),
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := ErrorMap}} ->
            BaseError#api_error{
                message = maps:get(<<"message">>, ErrorMap, BaseError#api_error.message),
                metadata = maps:get(<<"metadata">>, ErrorMap, #{})
            };
        _ ->
            BaseError
    end.

-spec from_body(map()) -> #api_error{}.
from_body(#{<<"error">> := #{<<"code">> := Code} = ErrorMap}) ->
    Type = code_to_type(Code),
    #api_error{
        type = Type,
        code = Code,
        message = maps:get(<<"message">>, ErrorMap, <<"">>),
        metadata = maps:get(<<"metadata">>, ErrorMap, #{})
    };
from_body(#{<<"error">> := ErrorMap}) ->
    #api_error{
        type = server_error,
        message = maps:get(<<"message">>, ErrorMap, <<"">>),
        metadata = maps:get(<<"metadata">>, ErrorMap, #{})
    }.

status_to_error(401) ->
    #api_error{type = auth_error, code = 401, message = <<"Unauthorized">>, metadata = #{}};
status_to_error(402) ->
    #api_error{type = insufficient_credits, code = 402,
               message = <<"Insufficient credits">>, metadata = #{}};
status_to_error(403) ->
    #api_error{type = forbidden, code = 403, message = <<"Forbidden">>, metadata = #{}};
status_to_error(429) ->
    #api_error{type = rate_limited, code = 429, message = <<"Rate limited">>, metadata = #{}};
status_to_error(Code) when Code >= 500 ->
    #api_error{type = server_error, code = Code, message = <<"Server error">>, metadata = #{}};
status_to_error(Code) ->
    #api_error{type = server_error, code = Code,
               message = iolist_to_binary(io_lib:format("HTTP ~p", [Code])), metadata = #{}}.

code_to_type(401) -> auth_error;
code_to_type(402) -> insufficient_credits;
code_to_type(403) -> forbidden;
code_to_type(429) -> rate_limited;
code_to_type(Code) when is_integer(Code), Code >= 500 -> server_error;
code_to_type(_) -> server_error.
