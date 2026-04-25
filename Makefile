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

test-dialyzer:
	$(REBAR3) dialyzer

test-eunit:
	$(REBAR3) eunit --app=erl_openrouter

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
