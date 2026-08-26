# Stage: The Model As A Session Choice

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: provider, vendor, model, session, menu, deepseek, kimi

## What Was Asked

The menu offered sixteen vendors nobody has an account with. Narrowing it
to the ones with a key left a second complaint: there are two vendors
here, and each of them has several models. Then the keys themselves,
with both vendors' model ids and endpoints.

## What Was Actually Wrong

A provider symbol answered three questions at once -- which vendor, over
which protocol, running which model. So a vendor speaking two protocols
read as two companies, and the several models each one serves were
nowhere at all.

The evidence was already in the configuration, written by hand:

```elisp
(setq chat-llm-kimi-code-default-model "k3")
(dolist (p '(kimi-code kimi-code-anthropic))
  (when-let ((cfg (chat-llm-get-provider-config p)))
    (plist-put cfg :model chat-llm-kimi-code-default-model)))
```

Reaching into the registry to change a model is not a workaround for a
missing setting; it is the absence of the feature. Choosing a model was
not something the product could do.

## Decisions

**Three fields, each with a default that leaves existing registrations
alone.** `:vendor` defaults to the provider symbol, so only the six
registrations that actually have a protocol variant say anything.
`:protocol` is injected by whichever compatibility factory registered the
provider, so no registration has to remember it. `:models` defaults to
the one default model, which is the honest extent of what was written
down rather than a claim about the vendor.

**The protocol is not a choice in the menu.** "I want k3" is the request;
which wire format carries it is not. A vendor appears once, reached
through its OpenAI-shaped provider because that is the path the rest of
chat.el is exercised against. The Anthropic variant stays reachable by
name, because it is a genuinely different code path and has to be
testable.

**nil is a value on the session, not an absence.** A session with no
model name follows the provider's default at the time of each request,
which is what almost every session wants and what makes a default changed
in configuration actually reach them. Writing the current default into
the session would freeze one snapshot of a changeable setting -- the
registry bug, moved somewhere harder to see.

**Provider and model change together.** `chat-set-model` takes both.
Between changing one and the other the session would point at a new
vendor holding the old vendor's model id, which is nobody's valid
pairing. Switching vendor without naming a model drops the old name, for
the same reason: carried over, `k3` would be sent to DeepSeek.

**Belonging and configuration are separate questions.**
`chat-llm-vendor-providers` reads the registry; `chat-llm-configured-vendors`
applies the key test. Written the other way round, a session sitting on a
keyless provider got a vendor heading with no models under it -- exactly
when it most needs to see where it is and move off.

**One function answers what a provider serves.** Both vendors answer
`GET /models` with precisely the list now written into the registration,
so discovery is real and cheap. It cannot be done synchronously while
drawing a menu, though, so this stage writes the list down and keeps the
question behind `chat-llm-provider-models`. The written list is the
fallback, not the authority, and replacing it is a change in one place.

**Provider and model are state, not identity.** They were serialized into
the JSONL header only, and the append path does not rewrite the header,
so a provider switched mid-session could be saved and lost. Both now
appear in the state entry, which the loader prefers.

## The Two Vendors

Verified against each vendor's own `/models`, not transcribed from prose:

- Kimi Code, `api.kimi.com/coding/v1`: `k3`, `k3-256k`,
  `kimi-for-coding`, `kimi-for-coding-highspeed`
- DeepSeek, `api.deepseek.com`: `deepseek-v4-flash`, `deepseek-v4-pro`,
  `deepseek-v4-flash-vision-exp`

`api.kimi.com` is Moonshot's own domain -- the earlier reading of it as
something other than official Kimi was wrong.

The DeepSeek registration named `deepseek-chat`. That id answers, but as
an alias: the response comes back reporting `deepseek-v4-flash`, so the
registration could not say which model a session had used. It now names a
real id, and the Anthropic-compatible endpoint at
`api.deepseek.com/anthropic` is registered alongside, same shape as Kimi
Code's.

## Verification

1075 tests pass, 24 new. On the registry: the three defaults, both
factories' protocols, one vendor over two protocols collapsing to one
with the OpenAI path as the way in, a single-protocol vendor using
whatever it has, an unconfigured vendor absent from the list but still
answering which providers belong to it, and the two real vendors' model
lists.

On the session: a new session pins nothing, a pinned name survives a
round trip, an unpinned one reads back unpinned rather than as a model
called "null", a provider changed mid-session persists, and a branch
inherits both.

On the menu and prompt: grouped by vendor, one item per model, the
current one marked, a two-protocol vendor appearing once with the
parenthetical stripped from its heading, the other protocol still
reachable by name, the prompt naming what the session pinned rather than
the provider default, an unpinned session following that default, a
cross-vendor model refused without half-moving the session, and the
pinned name present in the options the transport is handed -- absent when
nothing is pinned.

End to end with the real keys, through `chat-llm-request` rather than
curl: `kimi-code` with `k3-256k`, `deepseek` with `deepseek-v4-pro`, and
`deepseek-anthropic` with `deepseek-v4-flash` all return, and each
response echoes the model that was pinned, which is what proves the pin
reached the wire on all three paths.
