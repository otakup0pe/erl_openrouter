-module(openrouter_text).
%% @private
%% Internal module -- use {@link openrouter} for the public API.
%%
%% UTF-8 sanitization utilities. Replaces invalid byte sequences with
%% U+FFFD (replacement character) while preserving all valid multi-byte
%% content (accented characters, Indigenous language terms, emoji, etc.).

-export([sanitize_utf8/1]).
-export([sanitize_messages/1]).

%% @doc Sanitize a binary so it contains only valid UTF-8.
-spec sanitize_utf8(binary()) -> binary().
sanitize_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Result when is_binary(Result) -> Result;
        _ -> sanitize_utf8_bytes(Bin, <<>>)
    end.

%% @doc Sanitize the `content' field of each message in a message list.
-spec sanitize_messages([map()]) -> [map()].
sanitize_messages(Messages) when is_list(Messages) ->
    [sanitize_message(M) || M <- Messages].

-spec sanitize_message(map()) -> map().
sanitize_message(#{<<"content">> := Content} = Msg) when is_binary(Content) ->
    Msg#{<<"content">> => sanitize_utf8(Content)};
sanitize_message(Msg) ->
    Msg.

-spec sanitize_utf8_bytes(binary(), binary()) -> binary().
sanitize_utf8_bytes(<<>>, Acc) -> Acc;
sanitize_utf8_bytes(<<C/utf8, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, C/utf8>>);
sanitize_utf8_bytes(<<_, Rest/binary>>, Acc) ->
    sanitize_utf8_bytes(Rest, <<Acc/binary, 16#FFFD/utf8>>).
