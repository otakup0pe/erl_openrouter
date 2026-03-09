ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile test local-test local-eunit local-ct clean docker-build docker-test dialyzer shell

REBAR3 ?= rebar3
DOCKER_IMAGE ?= erl-openrouter-test:latest

all: compile

compile:
	$(REBAR3) compile

test: docker-test

docker-build:
	docker build -t $(DOCKER_IMAGE) -f Dockerfile.test .

docker-test: docker-build
	docker run -t --rm -v $(PWD):/app -w /app $(DOCKER_IMAGE) make local-test

local-test: local-eunit local-ct

local-eunit:
	$(REBAR3) eunit

local-ct:
	$(REBAR3) ct

clean:
	$(REBAR3) clean

dialyzer:
	$(REBAR3) dialyzer

shell:
	$(REBAR3) shell
