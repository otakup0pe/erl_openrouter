ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile test test-all test-local test-eunit test-ct test-dialyzer clean distclean docker-build docker-test dialyzer shell integration test-integration

REBAR3 ?= rebar3
COMPOSE ?= docker compose -f docker-compose.test.yml

all: compile

compile:
	$(REBAR3) compile

test: docker-test

test-all: docker-test integration

docker-build:
	$(COMPOSE) build

docker-test: docker-build
	$(COMPOSE) run --rm test

test-local: test-eunit test-ct test-dialyzer
	$(REBAR3) cover

test-dialyzer:
	$(REBAR3) dialyzer

EUNIT_MODULES = backoff_tests,auth_config_tests,circuit_breaker_pure_tests,embedding_request_tests,embedding_response_tests,error_classify_tests,generation_response_tests,http_tests,json_tests,key_response_tests,models_response_tests,rate_limiter_tests,request_build_tests,response_parse_tests,stream_tests,tools_tests,usage_tests

test-eunit:
	$(REBAR3) eunit --module=$(EUNIT_MODULES)

test-ct:
	$(REBAR3) ct --dir test

clean:
	$(REBAR3) clean

distclean: clean
	rm -rf _build
	$(COMPOSE) down -v

dialyzer:
	$(REBAR3) dialyzer

shell:
	$(REBAR3) shell

integration: docker-build
	$(COMPOSE) run --rm \
		-e OPENROUTER_API_KEY=$${OPENROUTER_API_KEY} \
		test make test-integration

test-integration:
	$(REBAR3) ct --dir test/integration
