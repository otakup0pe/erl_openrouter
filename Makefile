ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile test test-all test-local test-eunit test-ct test-dialyzer clean distclean docker-build docker-test dialyzer shell integration test-integration dev-upgrade

REBAR3 ?= rebar3
COMPOSE ?= docker compose -f docker-compose.test.yml

export BUILDX_BUILDER ?= default

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

EUNIT_MODULES = backoff_tests,auth_config_tests,circuit_breaker_pure_tests,embedding_request_tests,embedding_response_tests,error_classify_tests,generation_response_tests,http_tests,json_tests,key_response_tests,models_response_tests,rate_limiter_tests,request_build_tests,response_parse_tests,stream_tests,text_tests,tools_tests,usage_tests

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

# Unlock before resolving because rebar3 upgrade can leave git branch
# dependencies pinned to stale refs while still exiting successfully.
# `unlock --all` is required, not optional: rebar3 REJECTS the bare
# `rebar3 unlock` form, so dropping the flag means nothing un-pins and
# the bump resolves against the refs already in rebar.lock.
# verify-erlang-lock then reports which refs actually MOVED, against the
# baseline snapshotted before the container runs -- a missing dep is
# fatal, an unchanged ref is not (a dep already at its tip correctly
# does not move).
dev-upgrade: docker-build
	@mkdir -p _build
	@sh scripts/verify-erlang-lock --snapshot > _build/rebar-lock.before
	@target='$(DEP)'; \
	if [ -z "$$target" ]; then \
		echo "Bumping all git deps to latest allowed refs..."; \
		unlock_cmd='rebar3 unlock --all'; \
		rm_cmd='rm -rf _build/default/lib _build/test/lib'; \
	else \
		echo "Bumping $$target..."; \
		unlock_cmd="rebar3 unlock $$target"; \
		rm_cmd="rm -rf _build/default/lib/$$target _build/test/lib/$$target"; \
	fi; \
	$(COMPOSE) run --rm test sh -c "$$unlock_cmd && $$rm_cmd && rebar3 deps && rebar3 lock"
	@rc=0; sh scripts/verify-erlang-lock --since _build/rebar-lock.before $(DEP) || rc=$$?; \
		rm -f _build/rebar-lock.before; \
		exit $$rc
