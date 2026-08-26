# Stage — Auto, and declaring it on the command (2026-08-26)

## What prompted it

Two things were being called auto: a session's default command continuing
without being retyped, and an agent running rounds until its goal is met.
Only the first is done here.

The immediate friction was concrete. Shell work comes in runs, and every
line of a run needed its own `!`. That is the kind of thing that makes
someone stop using the surface and open a terminal.

## What changed

Commands are declared rather than listed per property.
`chat-ui--command-table` carries one entry each with `:handler`,
`:while-busy` and `:repeatable`, replacing a handler alist plus a separate
list of names allowed to run during a response — two lists whose only
relationship was containing the same strings.

A repeatable command claims plain input: after `!ls`, bare lines run as
shell until `/auto off`. `/cmd` and the bare `!` prefix are the same
command reached two ways, so both engage it.

It is a mode, so it is loud in three places: the status line reads
`auto: /cmd` beside the model, turning it on says so, and `/auto` reports
the state and names what could hold it. The literal escape takes one line
straight to the model regardless.

Two things outrank it. An explicit `/command` means itself. And a live
agent run takes plain input as steering, because sending it to a shell
would race the run and lose what the user meant to tell it.

The default lives on session metadata, so it survives a reopen, and
`chat-ui-default-command` takes an optional session so the status line
cannot disagree with the behaviour it describes.

## Where it departs from the request

The request named `/ask` as auto-triggering. It is not repeatable here,
for two reasons worth writing down rather than quietly implementing.
Plain input already goes to the model, so an ask command has nothing to
displace. And `/ask` in this codebase is the ephemeral query — it asks
without recording — so as a sticky default it would leave the conversation
silently unwritten, discovered a day later when the session is reopened
and the questions are gone.

`/agent` and `/plan` are repeatable when they exist. They are the second
sense of auto, which is not built.

## What guards it

794 tests. Ten new ones cover auto: off until claimed, a shell command
claiming plain input, the status line saying so, `/auto off` giving it
back, an explicit command still meaning itself, the literal escape getting
past it, survival across a reopen with the header intact, refusal of a
command that cannot be default, and a live run outranking it.

Slash commands also got the consistency guarantee the keymap has: a test
reads the names out of `chat-commands-help` and requires each to reach a
handler. It was probed with a fake name to confirm it bites rather than
passing vacuously. The nine names that answer nothing — `/new`, `/list`,
`/save`, `/clear` and five `/wiki-*` — are now listed in the test instead
of in a planning note, with a second test asserting the list does not
cover anything that works.

## Result

`!ls` then `wc -l *.el` runs both as shell, and `\what does that do` asks
the model, all in one session with the state on screen throughout —
checked by walking a real session, not only by assertion.
