-module(openrouter_error).

-include("openrouter.hrl").

-export([classify/1, classify/2, from_body/1]).

-spec classify(Reason :: term()) -> #api_error{}.
classify(timeout = Reason) ->
    #api_error{type = timeout, message = <<"Request timed out">>,
               metadata = #{reason => Reason}};
classify({failed_connect, Inner} = Reason) when is_list(Inner) ->
    Message = connect_failure_message(Inner),
    #api_error{type = connect_failed, message = Message,
               metadata = #{reason => Reason}};
classify(Reason) ->
    #api_error{type = server_error,
               message = iolist_to_binary(io_lib:format("~p", [Reason])),
               metadata = #{reason => Reason}}.

%% Walk the inner proplist from httpc's {failed_connect, [...]} error
%% and produce a human-readable message that names the specific
%% sub-cause. We intentionally do NOT catch-all the inner cause --
%% unknown sub-errors fall through to a generic formatter so the log
%% still carries the term, but named cases get friendlier messages.
connect_failure_message(Inner) ->
    Cause = extract_connect_cause(Inner),
    format_connect_cause(Cause).

extract_connect_cause([]) ->
    unknown;
extract_connect_cause([{to_address, _} | Rest]) ->
    extract_connect_cause(Rest);
extract_connect_cause([{inet, _, Cause} | _]) ->
    Cause;
extract_connect_cause([Cause | _]) ->
    Cause.

format_connect_cause(nxdomain) ->
    <<"DNS lookup failed: nxdomain">>;
format_connect_cause(timeout) ->
    <<"Connect timed out">>;
format_connect_cause(ehostunreach) ->
    <<"Host unreachable">>;
format_connect_cause(enetunreach) ->
    <<"Network unreachable">>;
format_connect_cause(econnrefused) ->
    <<"Connection refused">>;
format_connect_cause(econnreset) ->
    <<"Connection reset by peer">>;
format_connect_cause({tls_alert, _} = Alert) ->
    iolist_to_binary(io_lib:format("TLS handshake failed: ~p", [Alert]));
format_connect_cause(Other) ->
    iolist_to_binary(io_lib:format("Connect failed: ~p", [Other])).

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
