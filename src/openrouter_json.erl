-module(openrouter_json).

-export([encode/1, decode/1]).

-spec encode(term()) -> {ok, binary()} | {error, {parse_error, term()}}.
encode(Term) ->
    try
        case has_otp_json() of
            true ->
                {ok, iolist_to_binary(json:encode(Term))};
            false ->
                {ok, jsx:encode(Term)}
        end
    catch
        error:Reason ->
            {error, {parse_error, Reason}}
    end.

-spec decode(binary()) -> {ok, term()} | {error, {parse_error, term()}}.
decode(Bin) ->
    try
        case has_otp_json() of
            true ->
                {ok, json:decode(Bin)};
            false ->
                {ok, jsx:decode(Bin, [return_maps])}
        end
    catch
        error:Reason ->
            {error, {parse_error, Reason}}
    end.

-spec has_otp_json() -> boolean().
has_otp_json() ->
    case persistent_term:get({?MODULE, has_otp_json}, not_cached) of
        not_cached ->
            Result = erlang:function_exported(json, encode, 1),
            persistent_term:put({?MODULE, has_otp_json}, Result),
            Result;
        Cached ->
            Cached
    end.
