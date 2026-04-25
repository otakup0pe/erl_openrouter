-module(openrouter_error).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

%% @doc Error classification and construction for the OpenRouter client.
%%
%% Converts HTTP status codes, transport failures, and JSON error bodies into
%% uniform `#api_error{}' records. Use {@link classify/1} for transport errors,
%% {@link classify/2} for HTTP-level errors, and {@link local_error/2} for
%% client-originated errors.

-include("openrouter.hrl").

-export([classify/1, classify/2, from_body/1]).
-export([local_error/2, local_error/3]).
-export([truncate_body/1]).

-type error_type() :: auth_error | circuit_open | overloaded
                    | rate_limited | worker_crashed.
-export_type([error_type/0]).

%% @doc Build a client-originated error
-spec local_error(error_type(), binary()) -> #api_error{}.
local_error(Type, Message) ->
    local_error(Type, Message, #{}).

%% @doc Build a client-originated error with extra metadata.
-spec local_error(error_type(), binary(), map()) -> #api_error{}.
local_error(Type, Message, Extra) ->
    #api_error{type = Type, message = Message,
               metadata = Extra#{source => local}}.

%% @doc Classify a transport-level error into an `#api_error{}' record.
-spec classify(Reason :: term()) -> #api_error{}.
classify(timeout = Reason) ->
    #api_error{type = timeout, message = <<"Request timed out">>,
               metadata = #{reason => Reason, source => remote}};
classify({failed_connect, Inner} = Reason) when is_list(Inner) ->
    Message = connect_failure_message(Inner),
    #api_error{type = connect_failed, message = Message,
               metadata = #{reason => Reason, source => remote}};
classify(Reason) ->
    #api_error{type = server_error,
               message = iolist_to_binary(io_lib:format("~p", [Reason])),
               metadata = #{reason => Reason, source => remote}}.

%% Produce human-readable messages from httpc error tuple. Bubble up
%% details so consumers can actually see details.
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

%% @doc Classify an HTTP error response by status code and body.
-spec classify(StatusCode :: integer(), Body :: binary()) -> #api_error{}.
classify(StatusCode, Body) ->
    BaseError = status_to_error(StatusCode),
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := ErrorMap}} ->
            ServerMeta = maps:get(<<"metadata">>, ErrorMap, #{}),
            BaseError#api_error{
                message = maps:get(<<"message">>, ErrorMap, BaseError#api_error.message),
                metadata = ServerMeta#{source => remote}
            };
        _ ->
            BaseError#api_error{
                metadata = (BaseError#api_error.metadata)#{source => remote,
                                                           raw_body => truncate_body(Body)}
            }
    end.

truncate_body(Body) when byte_size(Body) =< 512 -> Body;
truncate_body(Body) -> binary:part(Body, 0, 512).

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
