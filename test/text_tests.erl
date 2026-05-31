-module(text_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for openrouter_text:ensure_utf8/1 and openrouter_text:sanitize_utf8/1.
%% When content is not valid UTF-8, ensure_utf8 tries Latin-1 re-encoding
%% first (preserving characters like §), then falls back to replacing
%% remaining invalid bytes with U+FFFD.
%% Valid UTF-8 content, including multi-byte characters, must pass through unchanged.

%% The UTF-8 encoding of U+FFFD is <<16#EF, 16#BF, 16#BD>>.
-define(REPLACEMENT, <<16#EF, 16#BF, 16#BD>>).

%% ===================================================================
%% ensure_utf8/1 tests
%% ===================================================================

%% --- Happy path: valid UTF-8 passes through unchanged ---

ensure_utf8_plain_ascii_test() ->
    Input = <<"Hello, world!">>,
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

ensure_utf8_empty_binary_test() ->
    ?assertEqual(<<>>, openrouter_text:ensure_utf8(<<>>)).

%% Multi-byte UTF-8 must be preserved, not stripped.
%% Hawaiian: Hāloa (ā = U+0101, two bytes)
ensure_utf8_hawaiian_preserved_test() ->
    Input = <<"H", 16#C4, 16#81, "loa">>,  % Hāloa
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

%% Lakota: Wakȟáŋ (ȟ = U+021F, á = U+00E1, ŋ = U+014B)
ensure_utf8_lakota_preserved_test() ->
    Input = <<"Wak", 16#C8, 16#9F,   % ȟ
              16#C3, 16#A1,            % á
              16#C5, 16#8B>>,          % ŋ
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

%% Em dash U+2014 (three bytes: E2 80 94)
ensure_utf8_em_dash_preserved_test() ->
    Input = <<"before ", 16#E2, 16#80, 16#94, " after">>,
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

%% Accented characters: café
ensure_utf8_accented_chars_preserved_test() ->
    Input = <<"caf", 16#C3, 16#A9>>,  % café
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

%% Four-byte emoji (U+1F600 = F0 9F 98 80)
ensure_utf8_emoji_preserved_test() ->
    Input = <<"smile: ", 16#F0, 16#9F, 16#98, 16#80>>,
    ?assertEqual(Input, openrouter_text:ensure_utf8(Input)).

%% --- Latin-1 fallback: bare Latin-1 bytes get properly re-encoded ---

%% Bare 0xA7 (§ in Latin-1) should become proper UTF-8 <<C2 A7>>,
%% NOT U+FFFD replacement character.
ensure_utf8_latin1_section_sign_test() ->
    Input = <<16#A7>>,
    Expected = <<16#C2, 16#A7>>,  % § in UTF-8
    ?assertEqual(Expected, openrouter_text:ensure_utf8(Input)).

%% Full Latin-1 string: "§ection"
ensure_utf8_latin1_section_word_test() ->
    Input = <<16#A7, "ection">>,
    Expected = <<16#C2, 16#A7, "ection">>,
    ?assertEqual(Expected, openrouter_text:ensure_utf8(Input)).

%% Latin-1 copyright sign © (0xA9)
ensure_utf8_latin1_copyright_test() ->
    Input = <<"Copyright ", 16#A9, " 2026">>,
    Expected = <<"Copyright ", 16#C2, 16#A9, " 2026">>,
    ?assertEqual(Expected, openrouter_text:ensure_utf8(Input)).

%% Mixed valid UTF-8 + bare Latin-1: the entire binary gets Latin-1
%% treatment since UTF-8 validation fails on the whole thing.
ensure_utf8_mixed_valid_utf8_and_latin1_test() ->
    %% "café" with valid é (C3 A9) followed by bare § (A7)
    %% When UTF-8 validation fails, Latin-1 fallback treats ALL bytes as Latin-1.
    %% C3 in Latin-1 = Ã, A9 in Latin-1 = ©, A7 in Latin-1 = §
    Input = <<"caf", 16#C3, 16#A9, 16#A7>>,
    Result = openrouter_text:ensure_utf8(Input),
    %% The result must be valid UTF-8
    ?assertEqual(Result, unicode:characters_to_binary(Result, utf8)),
    %% And must be encodable as JSON without crashing
    {ok, _} = openrouter_json:encode(#{<<"v">> => Result}).

%% Control bytes: Latin-1 fallback handles these (0x14 = DC4 control char)
ensure_utf8_control_byte_test() ->
    Input = <<"before", 16#14, "after">>,
    Result = openrouter_text:ensure_utf8(Input),
    %% Latin-1 fallback treats 0x14 as U+0014, which is valid Unicode
    ?assertEqual(Result, unicode:characters_to_binary(Result, utf8)),
    %% Valid parts preserved
    ?assert(binary:match(Result, <<"before">>) =/= nomatch),
    ?assert(binary:match(Result, <<"after">>) =/= nomatch).

%% --- Non-binary inputs pass through unchanged ---

ensure_utf8_atom_passthrough_test() ->
    ?assertEqual(hello, openrouter_text:ensure_utf8(hello)).

ensure_utf8_integer_passthrough_test() ->
    ?assertEqual(42, openrouter_text:ensure_utf8(42)).

ensure_utf8_undefined_passthrough_test() ->
    ?assertEqual(undefined, openrouter_text:ensure_utf8(undefined)).

ensure_utf8_list_passthrough_test() ->
    ?assertEqual([1, 2, 3], openrouter_text:ensure_utf8([1, 2, 3])).

%% ===================================================================
%% sanitize_utf8/1 backward-compat tests (delegates to ensure_utf8)
%% ===================================================================

plain_ascii_unchanged_test() ->
    Input = <<"Hello, world!">>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

empty_binary_test() ->
    ?assertEqual(<<>>, openrouter_text:sanitize_utf8(<<>>)).

hawaiian_preserved_test() ->
    Input = <<"H", 16#C4, 16#81, "loa">>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

lakota_preserved_test() ->
    Input = <<"Wak", 16#C8, 16#9F, 16#C3, 16#A1, 16#C5, 16#8B>>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

em_dash_preserved_test() ->
    Input = <<"before ", 16#E2, 16#80, 16#94, " after">>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

accented_chars_preserved_test() ->
    Input = <<"caf", 16#C3, 16#A9>>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

emoji_preserved_test() ->
    Input = <<"smile: ", 16#F0, 16#9F, 16#98, 16#80>>,
    ?assertEqual(Input, openrouter_text:sanitize_utf8(Input)).

%% sanitize_utf8 now uses Latin-1 fallback, so bare 0xA7 becomes § not U+FFFD
orphaned_continuation_byte_test() ->
    Input = <<"before", 16#A7, "after">>,
    Expected = <<"before", 16#C2, 16#A7, "after">>,  % § in UTF-8
    ?assertEqual(Expected, openrouter_text:sanitize_utf8(Input)).

%% ===================================================================
%% sanitize_messages/1 tests
%% ===================================================================

%% sanitize_messages walks all binary values in each message map
sanitize_messages_all_values_test() ->
    Msgs = [#{<<"role">> => <<"user">>,
              <<"content">> => <<"hello ", 16#A7>>,
              <<"name">> => <<"test", 16#A9>>}],
    [Sanitized] = openrouter_text:sanitize_messages(Msgs),
    %% Content: bare 0xA7 -> Latin-1 § in UTF-8
    Content = maps:get(<<"content">>, Sanitized),
    ?assertEqual(<<"hello ", 16#C2, 16#A7>>, Content),
    %% Name: bare 0xA9 -> Latin-1 © in UTF-8
    Name = maps:get(<<"name">>, Sanitized),
    ?assertEqual(<<"test", 16#C2, 16#A9>>, Name).

%% Non-binary values in message maps pass through
sanitize_messages_non_binary_values_test() ->
    Msgs = [#{<<"role">> => <<"user">>,
              <<"content">> => <<"hello">>,
              <<"temperature">> => 0.7}],
    [Sanitized] = openrouter_text:sanitize_messages(Msgs),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Sanitized)).

%% ===================================================================
%% Integration tests
%% ===================================================================

sanitized_encodes_as_json_test() ->
    Input = <<"hello ", 16#A7, " world">>,
    Sanitized = openrouter_text:ensure_utf8(Input),
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
    %% The § should have been re-encoded via Latin-1, not replaced with U+FFFD
    ?assert(binary:match(Content, <<16#C2, 16#A7>>) =/= nomatch),
    %% The valid parts should be preserved
    ?assert(binary:match(Content, <<"hello ">>) =/= nomatch),
    ?assert(binary:match(Content, <<" world">>) =/= nomatch).
