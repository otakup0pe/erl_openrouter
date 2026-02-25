.PHONY: all compile test eunit ct clean

REBAR3 ?= rebar3

all: compile

compile:
	$(REBAR3) compile

test: eunit ct

eunit:
	$(REBAR3) eunit

ct:
	$(REBAR3) ct

clean:
	$(REBAR3) clean

dialyzer:
	$(REBAR3) dialyzer

shell:
	$(REBAR3) shell
