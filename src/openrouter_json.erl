-module(openrouter_json).
%% @private
%% Internal module -- use {@link openrouter} for the public API.
%% Parsing handles both jsx and first-party json modules, so there is a bit of
%% duplicated error handling. Self-discovers json module, falling back to jsx.
%% Things will go badly if neither are available.
-export([encode/1, decode/1]).
-export([maybe_set/4]).

-spec encode(term()) -> {ok, binary()} | {error, {parse_error, {badarg, term()} | {invalid_byte, integer()}}}.
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
            {error, {parse_error, {badarg, Term}}};
        error:{invalid_byte, Byte} ->
            %% OTP 27 json:encode throws {invalid_byte, N} for non-UTF-8
            %% bytes. Sanitize all binaries in the term and retry once.
            logger:warning("openrouter_json: invalid byte ~B in term, "
                           "sanitizing and retrying", [Byte]),
            try
                Sanitized = sanitize_term(Term),
                {ok, iolist_to_binary(json:encode(Sanitized))}
            catch
                error:{invalid_byte, Byte2} ->
                    {error, {parse_error, {invalid_byte, Byte2}}}
            end
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

%% Recursively walk a term and sanitize all binaries to valid UTF-8.
%% Used as a fallback when json:encode hits an invalid byte.
-spec sanitize_term(term()) -> term().
sanitize_term(Bin) when is_binary(Bin) ->
    openrouter_text:ensure_utf8(Bin);
sanitize_term(Map) when is_map(Map) ->
    maps:map(fun(_K, V) -> sanitize_term(V) end, Map);
sanitize_term(List) when is_list(List) ->
    [sanitize_term(V) || V <- List];
sanitize_term(Other) ->
    Other.

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
