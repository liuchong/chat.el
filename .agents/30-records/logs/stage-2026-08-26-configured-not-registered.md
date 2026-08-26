# Stage: Registered Is Not Configured

- Type: log
- Attention: record
- Status: done
- Scope: project
- Tags: providers, configuration, prompt, menu
- Date: 2026-08-26

## What Was Reported

The provider menu offered a long list of models nobody has configured.
Sensed configuration was asked for by name: the program should know what
is actually set up and show that.

## The Confusion In One Line

`chat-llm-enabled-providers` answers "which providers did chat.el
register", and that was being read as "which providers can this machine
use".

chat.el registers every vendor it knows how to speak to at load time, and
`chat-llm-enabled-providers` (the variable) defaults to nil meaning "no
exclusions". So the function returns all sixteen, forever, on every
machine. Measured against the reporting configuration: sixteen
registered, sixteen enabled, four with a key.

## The Test

A key. Nothing else in a registration says whether an account exists
behind it, and a provider without a key fails every request it is given,
so `chat-llm-provider-configured-p` is enabled plus a key that resolves.
Three consequences worth stating:

Computed at display time, not cached. A key configured halfway through a
session should count from the next look, and one removed should stop
counting. The cost is one key lookup per provider -- 0.34ms for all
sixteen in the reporting configuration -- and the redraw path runs on
user actions, not on a timer. The contract this puts on `:api-key-fn` is
that it be cheap or cache its own answer, which the request path already
required of it.

A key lookup that signals answers no. This runs while drawing a prompt,
and a provider whose key cannot be fetched is unusable either way, so the
error belongs to the request that tries it.

The session's own provider is offered whether or not it has a key.
Otherwise a session pointed at an unconfigured provider could neither see
where it was nor move off it.

## Offered Versus Accepted

`chat-set-model` now completes over the configured providers but no
longer requires a match: a key that is moments from being set is a
reason to switch, and the existing registration check still catches a
name that is nobody's provider.

## What This Does Not Fix

The menu now reads, under the reporting configuration:

    Ark Code (Anthropic)   ark-code-latest
    Ark Code               ark-code-latest
    Kimi Code (Anthropic)  k3
    Kimi Code              k3

Two vendors, four entries, because a vendor speaking two protocols is
registered twice -- and one model each, because a provider registration
carries exactly one model name. So "each vendor has several models" is not
a display bug: there is no model dimension in the data at all. The
snapshot is why the reporting configuration has to reach into the registry
with `plist-put` to change the Kimi model, with a comment explaining that
a later `setq` only reaches the OpenAI path.

Making the menu vendor-then-model needs three things that do not exist: a
model list per provider (discoverable, since the OpenAI-compatible
endpoint answers `GET /v1/models`), a model name on the session rather
than only a provider symbol, and a vendor identity so two protocol
variants stop reading as two vendors. That is a spec, not a patch.

## Verification

1051 tests pass, six new. The primitive is tested over a registry of its
own, since every registration in `test-chat-llm.el` mutates the global one
permanently and never takes it back -- which is exactly why the UI tests
now state which providers are configured instead of inheriting whatever
ran first.
