-module(text_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for openrouter_text:sanitize_utf8/1.
%% Invalid UTF-8 sequences must be replaced with U+FFFD (replacement character).
%% Valid UTF-8 content, including multi-byte characters, must pass through unchanged.

%% The UTF-8 encoding of U+FFFD is <<16#EF, 16#BF, 16#BD>>.
-define(REPLACEMENT, <<16#EF, 16#BF, 16#BD>>).

%% --- Happy path: valid content passes through unchanged ---

plain_ascii_unchanged_test() ->
    Input = <<"Hello, world!">>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

empty_binary_test() ->
    ?assertEqual(<<>>, openrouter_text:sanitize_utf8(<<>>)).

%% Multi-byte UTF-8 must be preserved, not stripped.
%% Hawaiian: Hāloa (ā = U+0101, two bytes)
hawaiian_preserved_test() ->
    Input = <<"H", 16#C4, 16#81, "loa">>,  % Hāloa
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% Lakota: Wakȟáŋ (ȟ = U+021F, á = U+00E1, ŋ = U+014B)
lakota_preserved_test() ->
    Input = <<"Wak", 16#C8, 16#9F,   % ȟ
              16#C3, 16#A1,            % á
              16#C5, 16#8B>>,          % ŋ
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% Em dash U+2014 (three bytes: E2 80 94)
em_dash_preserved_test() ->
    Input = <<"before ", 16#E2, 16#80, 16#94, " after">>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% Accented characters
accented_chars_preserved_test() ->
    Input = <<"caf", 16#C3, 16#A9>>,  % café
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% Four-byte emoji (U+1F600 = F0 9F 98 80)
emoji_preserved_test() ->
    Input = <<"smile: ", 16#F0, 16#9F, 16#98, 16#80>>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% --- Invalid sequences: must be replaced with U+FFFD ---

%% Bare 0xA7: an orphaned continuation byte (the crash from the bug report).
orphaned_continuation_byte_test() ->
    Input = <<"before", 16#A7, "after">>,
    Expected = <<"before", ?REPLACEMENT/binary, "after">>,
    ?assertEqual(Expected, openrouter_text:sanitize_utf8(Input)).

%% Bare 0xC2 at end of string: truncated two-byte lead byte.
truncated_lead_byte_test() ->
    Input = <<"text", 16#C2>>,
    Expected = <<"text", ?REPLACEMENT/binary>>,
    ?assertEqual(Expected, openrouter_text:sanitize_utf8(Input)).

%% Multiple consecutive bad bytes: each gets its own replacement.
multiple_bad_bytes_test() ->
    Input = <<16#80, 16#81, 16#82>>,
    Expected = <<?REPLACEMENT/binary, ?REPLACEMENT/binary, ?REPLACEMENT/binary>>,
    ?assertEqual(Expected, openrouter_text:sanitize_utf8(Input)).

%% --- Mixed valid + invalid: valid parts must survive ---

mixed_valid_and_invalid_test() ->
    %% "café" with valid é (C3 A9), then a bare continuation byte (A7), then "ok"
    Input = <<"caf", 16#C3, 16#A9, 16#A7, "ok">>,
    Expected = <<"caf", 16#C3, 16#A9, ?REPLACEMENT/binary, "ok">>,
    ?assertEqual(Expected, openrouter_text:sanitize_utf8(Input)).

%% Truncated three-byte sequence mid-string
truncated_three_byte_test() ->
    %% E2 80 without third byte, then ASCII
    Input = <<"a", 16#E2, 16#80, "b">>,
    %% E2 is a lead byte expecting 2 continuation bytes, 80 is the first
    %% continuation, then "b" (0x62) is not a continuation byte.
    %% The E2 80 sequence is invalid, each bad byte gets U+FFFD.
    %% Then "b" is valid ASCII.
    Result = openrouter_text:sanitize_utf8(Input),
    %% Verify valid parts survive
    ?assert(binary:match(Result, <<"a">>) =/= nomatch),
    ?assert(binary:match(Result, <<"b">>) =/= nomatch),
    %% Verify invalid bytes were replaced (at least one replacement char)
    ?assert(binary:match(Result, ?REPLACEMENT) =/= nomatch).

%% --- Integration: sanitized content can be JSON-encoded ---

sanitized_encodes_as_json_test() ->
    Input = <<"hello ", 16#A7, " world">>,
    Sanitized = openrouter_text:sanitize_utf8(Input),
    %% Must not crash json:encode
    {ok, _Json} = openrouter_json:encode(#{<<"content">> => Sanitized}).

%% Build request with invalid UTF-8 in message content should not crash
build_request_with_bad_utf8_test() ->
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"hello ", 16#A7, " world">>}],
    %% This would crash before the fix with {invalid_byte, 167}
    Json = openrouter_chat:build_request(Messages, #{}),
    ?assert(is_binary(Json)),
    {ok, Decoded} = openrouter_json:decode(Json),
    [Msg] = maps:get(<<"messages">>, Decoded),
    Content = maps:get(<<"content">>, Msg),
    %% The invalid byte should have been replaced, not stripped
    ?assert(binary:match(Content, ?REPLACEMENT) =/= nomatch),
    %% The valid parts should be preserved
    ?assert(binary:match(Content, <<"hello ">>) =/= nomatch),
    ?assert(binary:match(Content, <<" world">>) =/= nomatch).
