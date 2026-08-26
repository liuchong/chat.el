# 0011 — Auto, and declaring it on the command

Status: accepted
Date: 2026-08-26

## Context

Two different things were being called auto.

One is default-command continuation, the way a terminal-style surface
lets a run of shell commands go without a prefix on every line. The other
is an agent running several rounds until its goal is met, the way `pi`,
`kimi-cli`, `cursor` and `codex` do.

They are not the same mechanism and only the first is settled here.

The request also named which commands should engage it — `!!`, `/ask`,
`/agent`, `/plan`, external AI calls — and which should not: `/goal`,
`/cd`, `/pwd`, `/status`. The stated rule is commands that can or need to
run several times.

The table it had to be expressed in was two constants: an alist of name
to handler, and a separate list of the names allowed to run during a
response. Every new per-command property meant a third list somewhere
else, and a name present in one and missing from another fails silently.

## Decision

### The property goes on the command

`chat-ui--command-table` holds one entry per command, carrying its
handler, `:while-busy` and `:repeatable`. Adding a property means adding
a key, not another list to keep in step.

### Which commands are repeatable, and one disagreement with the request

Shell is. `/cmd` and the bare `!` prefix both engage auto, because `!ls`
and `/cmd ls` are the same command reached two ways.

Asking the model is not, and this departs from the request as stated.
Plain input already goes to the model, so nominating an ask command as the
default is a no-op — there is nothing for it to displace. And `/ask` in
this codebase is specifically the *ephemeral* query: it asks without
recording. As a sticky default it would leave the conversation silently
unwritten, which is the kind of thing noticed a day later when the session
is reopened and the questions are gone.

`/agent` and `/plan` do not exist yet. When they do they are repeatable —
they are the second sense of auto, below.

`/goal`, `/cd`, `/pwd` are not, matching the request: a goal is a standing
objective, not a loop, and there is no sense in which changing directory
wants to become what plain text means.

### It is a mode, so it is loud

An invisible mode that eats prose is worse than typing the prefix. Three
things carry it: the status line reads `auto: /cmd` alongside the model,
turning it on says so in the echo area, and `/auto` with no argument
reports the state and lists what could hold it.

The way out is `/auto off`. The way past it for one line is the literal
escape, which already existed.

### What outranks it

An explicit `/command` means itself — auto claims plain input, not
everything.

A live agent run also outranks it. While a response is going, plain input
steers that run. Sending it to a shell instead would race the run and lose
what the user meant to say to it.

### It lives on the session

Session metadata, not a buffer-local. A mode that silently expires on
reopen is as confusing as one you cannot see. `chat-ui-default-command`
takes an optional session for the same reason: the status line is drawn
for a session that may not yet be the buffer's, and a header disagreeing
with the behaviour is worse than no header.

## Consequences

The two constants are gone. `chat-ui--control-slash-commands` in
particular was a list whose only relationship to the handler table was
that both happened to contain the same strings.

Slash commands now have the consistency guarantee the keymap got in
decision 0009: a test reads the names out of `chat-commands-help` and
requires each to reach a handler. Nine that answer nothing — `/new`,
`/list`, `/save`, `/clear` and the five `/wiki-*` — are named in an
explicit list in the test rather than left implicit in a planning note.
Either they get built or they leave the help.

## Not decided here

The second sense of auto — an agent running rounds until its goal is met
rather than until it stops calling tools — is not implemented. The pieces
are in place around it: the step budget bounds the rounds and tells the
model where it stands, and the transcript records each round. What is
missing is the completion criterion, and inventing one that stops on
"looks done" is how a loop either quits early or never quits.

Also not decided: `/subagent`, `/send [agent-id]`, and whether external AI
tools arrive as one `/call_ai <tool>` rather than a command per vendor.
