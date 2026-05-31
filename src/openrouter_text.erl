-module(openrouter_text).
%% @private
%% Internal module -- use {@link openrouter} for the public API.
%%
%% UTF-8 sanitization utilities. When content is not valid UTF-8, tries
%% Latin-1 re-encoding first (preserving characters like §, ©, ñ), then
%% falls back to replacing remaining invalid bytes with U+FFFD.
%% Preserves all valid multi-byte content (accented characters, Indigenous
%% language terms, emoji, etc.).

-export([ensure_utf8/1]).
-export([sanitize_utf8/1]).
-export([sanitize_messages/1]).

%% @doc Ensure a value contains valid UTF-8. For binaries, validates and
%% re-encodes if needed (Latin-1 fallback, then byte-level replacement).
%% Logs a warning when sanitization was required.
%% Non-binary values (atoms, integers, etc.) pass through unchanged.
-spec ensure_utf8(term()) -> term().
ensure_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Result when is_binary(Result) ->
            Result;
        _ ->
            %% UTF-8 validation failed -- try Latin-1 interpretation
            Sanitized = case unicode:characters_to_binary(Bin, latin1, utf8) of
                Latin1Result when is_binary(Latin1Result) ->
                    Latin1Result;
                _ ->
                    %% Latin-1 also failed (shouldn't happen for
                    %% single-byte input, but be defensive) --
                    %% strip/replace invalid bytes
                    sanitize_utf8_bytes(Bin, <<>>)
            end,
            Preview = binary:part(Bin, 0, min(byte_size(Bin), 100)),
            logger:warning("openrouter_text: sanitized non-UTF-8 binary "
                           "(~B bytes, preview: ~p)", [byte_size(Bin), Preview]),
            Sanitized
    end;
ensure_utf8(Other) ->
    Other.

%% @doc Sanitize a binary so it contains only valid UTF-8.
%% Kept for backward compatibility; prefer ensure_utf8/1 for new code.
-spec sanitize_utf8(binary()) -> binary().
sanitize_utf8(Bin) when is_binary(Bin) ->
    ensure_utf8(Bin).

%% @doc Sanitize all binary string values in each message map.
-spec sanitize_messages([map()]) -> [map()].
sanitize_messages(Messages) when is_list(Messages) ->
    [sanitize_message(M) || M <- Messages].

-spec sanitize_message(map()) -> map().
sanitize_message(Msg) when is_map(Msg) ->
    maps:map(fun(_Key, Value) -> ensure_utf8_value(Value) end, Msg);
sanitize_message(Other) ->
    Other.

%% Walk values: binaries get ensure_utf8, lists get recursed,
%% nested maps get recursed, everything else passes through.
-spec ensure_utf8_value(term()) -> term().
ensure_utf8_value(Bin) when is_binary(Bin) ->
    ensure_utf8(Bin);
ensure_utf8_value(List) when is_list(List) ->
    [ensure_utf8_value(V) || V <- List];
ensure_utf8_value(Map) when is_map(Map) ->
    maps:map(fun(_K, V) -> ensure_utf8_value(V) end, Map);
ensure_utf8_value(Other) ->
    Other.

-spec sanitize_utf8_bytes(binary(), binary()) -> binary().
sanitize_utf8_bytes(<<>>, Acc) -> Acc;
sanitize_utf8_bytes(<<C/utf8, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, C/utf8>>);
sanitize_utf8_bytes(<<_, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, 16#FFFD/utf8>>).
