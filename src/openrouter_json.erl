-module(openrouter_json).
%% @private
%% Internal module -- use {@link openrouter} for the public API.
%% Parsing handles both jsx and first-party json modules, so there is a bit of
%% duplicated error handling. Self-discovers json module, falling back to jsx.
%% Things will go badly if neither are available.
-export([encode/1, decode/1]).
-export([maybe_set/4]).

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
        error:badarg ->
            {error, {parse_error, {badarg, Term}}}
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
        error:badarg ->
            {error, {parse_error, badarg}};
        error:{invalid_byte, _} = Reason ->
            {error, {parse_error, Reason}};
        error:{unexpected, _, _} = Reason ->
            {error, {parse_error, Reason}};
        error:{unexpected_end, _} = Reason ->
            {error, {parse_error, Reason}}
    end.

-spec maybe_set(binary(), atom(), map(), map()) -> map().
maybe_set(JsonKey, OptKey, Opts, Map) ->
    case maps:get(OptKey, Opts, undefined) of
        undefined -> Map;
        Value -> Map#{JsonKey => Value}
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
