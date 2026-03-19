-module(embedding_response_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that openrouter_embeddings:parse_response/1 correctly parses
%% success and error responses from the OpenRouter embeddings endpoint.

success_single_embedding_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"object">> => <<"list">>,
        <<"model">> => <<"openai/text-embedding-3-small">>,
        <<"data">> => [#{
            <<"object">> => <<"embedding">>,
            <<"index">> => 0,
            <<"embedding">> => [0.1, -0.2, 0.3, 0.4, -0.5]
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 4,
            <<"total_tokens">> => 4
        }
    }),
    {ok, Response} = openrouter_embeddings:parse_response(Json),
    ?assertEqual(<<"openai/text-embedding-3-small">>,
                 Response#embedding_response.model),
    ?assertEqual(1, length(Response#embedding_response.data)),
    [Item] = Response#embedding_response.data,
    ?assertEqual(0, maps:get(index, Item)),
    ?assertEqual([0.1, -0.2, 0.3, 0.4, -0.5], maps:get(embedding, Item)),
    ?assertEqual(4, maps:get(<<"prompt_tokens">>,
                             Response#embedding_response.usage)).

success_batch_embedding_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"model">> => <<"test-model">>,
        <<"data">> => [
            #{<<"index">> => 0, <<"embedding">> => [0.1, 0.2]},
            #{<<"index">> => 1, <<"embedding">> => [0.3, 0.4]},
            #{<<"index">> => 2, <<"embedding">> => [0.5, 0.6]}
        ],
        <<"usage">> => #{<<"prompt_tokens">> => 12, <<"total_tokens">> => 12}
    }),
    {ok, Response} = openrouter_embeddings:parse_response(Json),
    ?assertEqual(3, length(Response#embedding_response.data)),
    [First, Second, Third] = Response#embedding_response.data,
    ?assertEqual(0, maps:get(index, First)),
    ?assertEqual(1, maps:get(index, Second)),
    ?assertEqual(2, maps:get(index, Third)),
    ?assertEqual([0.5, 0.6], maps:get(embedding, Third)).

missing_optional_fields_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => [#{
            <<"embedding">> => [1.0, 2.0]
        }]
    }),
    {ok, Response} = openrouter_embeddings:parse_response(Json),
    ?assertEqual(undefined, Response#embedding_response.model),
    ?assertEqual(#{}, Response#embedding_response.usage),
    [Item] = Response#embedding_response.data,
    ?assertEqual(0, maps:get(index, Item)),
    ?assertEqual([1.0, 2.0], maps:get(embedding, Item)).

error_in_body_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 429,
            <<"message">> => <<"Rate limit exceeded">>
        }
    }),
    {error, ApiError} = openrouter_embeddings:parse_response(Json),
    ?assertEqual(rate_limited, ApiError#api_error.type).

missing_data_field_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"model">> => <<"test">>,
        <<"usage">> => #{}
    }),
    ?assertEqual({error, {parse_error, missing_data_field}},
                 openrouter_embeddings:parse_response(Json)).

invalid_json_test() ->
    ?assertMatch({error, {parse_error, _}},
                 openrouter_embeddings:parse_response(<<"not json">>)).

empty_data_list_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"model">> => <<"test">>,
        <<"data">> => [],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_embeddings:parse_response(Json),
    ?assertEqual([], Response#embedding_response.data).

high_dimensional_vector_test() ->
    %% Simulate a 1536-dim vector (just verify it round-trips)
    Vector = [float(I) / 1536 || I <- lists:seq(1, 1536)],
    {ok, Json} = openrouter_json:encode(#{
        <<"model">> => <<"openai/text-embedding-3-small">>,
        <<"data">> => [#{<<"index">> => 0, <<"embedding">> => Vector}],
        <<"usage">> => #{<<"prompt_tokens">> => 100, <<"total_tokens">> => 100}
    }),
    {ok, Response} = openrouter_embeddings:parse_response(Json),
    [Item] = Response#embedding_response.data,
    Embedding = maps:get(embedding, Item),
    ?assertEqual(1536, length(Embedding)).
