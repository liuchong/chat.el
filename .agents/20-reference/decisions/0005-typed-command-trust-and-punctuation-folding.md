# Decision 0005

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: input-commands
- Tags: commands, shell, trust, punctuation, working-directory

## Title

Typed commands carry user trust, and punctuation folding stays in syntax positions

## Context

Chat input grew a command layer covering shell execution, a session
working directory, and ephemeral queries. Two questions had to be settled
before the layer could be implemented.

The first is trust. `chat-tool-shell-execute` accepts only the commands in
`chat-tool-shell-allowed-commands` and rejects shell metacharacters,
which exists because tool arguments come from a model and cannot be
trusted. Applying the same list to a command a person typed made ordinary
work impossible: no pipes, no redirection, and no `git`. The old fallback
was worse than inconsistent. It ran `call-process-shell-command` with no
restriction at all whenever the shell tool was disabled, so turning the
tool off granted more power than leaving it on.

The second is punctuation. Chinese input methods produce fullwidth
punctuation, so `！ls` and `／cd` never reached a command. Folding the
whole input line to ASCII would fix the prefix and silently corrupt
payloads: a shell body or a question that legitimately contains `，` or
`（）` would be rewritten before it ran.

## Decision

- Treat a command a person typed as a separate trust level from a command
  a model proposed. Typed commands run through the system shell by
  default, controlled by `chat-ui-shell-unrestricted`. Model-supplied
  arguments stay on the restricted argv path with the allowed command
  list. The two paths never merge.
- Keep the restriction rule in one direction only. There is no mode where
  disabling a safety feature increases what the model can run.
- Fold fullwidth punctuation only in positions the parser owns: the
  leading prefix, the slash command name, and the separator before the
  argument. Directory arguments additionally fold `／` and `～`, because
  the parser resolves those paths itself.
- Never fold a shell body, an AI prompt, literal text, or any other
  argument. Those reach their destination byte for byte.
- Keep the working directory on the session rather than the buffer, and
  let an explicit choice by the user outrank the project root that code
  mode detects.

## Consequences

- `!git status` and `!ls | wc -l` work, which they did not before.
- A user who wants the stricter behavior sets `chat-ui-shell-unrestricted`
  to nil and gets the same limits the model has.
- Tooling safety guidance that forbids shell-string execution continues to
  apply to the tool path, which is what it was written for. The typed path
  documents its own boundary instead of quietly widening the tool path.
- Fullwidth acceptance can be extended by adding a pair to the folding
  table, without revisiting how arguments are handled.
- Because the working directory is session state, file tools reached
  through `./` in `chat-files-allowed-directories` follow the user's
  choice. The allowed directory list is deliberately not widened by a
  directory change, so pointing a session somewhere does not by itself
  grant the model access there.
