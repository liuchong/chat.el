# Decision 0014

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: input-commands
- Tags: commands, fullwidth, normalization, boundaries, shell
- Supersedes: the folding half of 0005

## Title

Normalization follows ownership: chat.el folds its own command language and nothing else

## Context

`/ｈｅｌｐ` was not a command. Decision 0005 established that fullwidth
input has to reach the same commands as ASCII, and implemented it as a
table of punctuation pairs — because punctuation was what the first report
was about. It even recorded, as a consequence, that "fullwidth acceptance
can be extended by adding a pair to the folding table". That sentence was
the bug: an input method is not in fullwidth mode for the punctuation
alone. It produces `／ｈｅｌｐ`, and the name is affected exactly as much
as the slash. A list of instances was standing in for a Unicode range.

Widening the range then exposed the harder question. The parser
deliberately does not fold arguments, and that rule is right: the same
position holds a shell body in `/cmd` and a prompt in `/send`, where a
fullwidth character may be exactly what was meant. But `/auto ｃｍｄ` did
nothing useful, because `/auto` does not pass its argument on — it compares
it against a command name.

So "syntax versus data" turned out to be the wrong axis. It describes the
symptom and gives no answer for `/auto`, whose argument is neither. The
question is not what a string looks like. It is **whose command language
the string belongs to**.

## The principle

A string is part of chat.el's command language when chat.el is the thing
that interprets it. Only those strings are normalized.

Work the boundary out per position, not per command:

- `！ls` — `！` is chat.el's. It is shorthand for `/cmd`, and shorthand for
  a command is a command. Fold it.
- `！ls` — `ls` is not chat.el's. It is the argument of `/cmd`, the content
  handed to whatever executes commands. chat.el has no authority to
  interpret it, and therefore none to rewrite it. Leave it byte for byte.
- `/auto ｃｍｄ` — the argument names one of chat.el's own commands. It
  never leaves the program. Fold it.
- `/send 请你做一轮优化` — the argument is for the model. Not chat.el's.
  Leave it.

The executor behind `/cmd` happens to be a shell. That is incidental: it is
logically just a thing that executes commands, and the rule would be the
same if it were something else. What matters is that the string is leaving.

Two corollaries fall out of this rather than needing separate rules:

- A command named in Chinese is not folded, because CJK ideographs are
  outside the block. `/发送` is chat.el's command, spelled in a script that
  has no halfwidth form to fold to.
- `/cd` folds `／` and `～` and nothing else. The path separator and home
  are chat.el's syntax — the parser resolves them itself — while the rest
  of the path is a name on someone's disk.

## Decision

- Normalize fullwidth to ASCII by mapping U+FF01–U+FF5E arithmetically,
  plus U+3000 to space. Not a list. A list of instances cannot be right
  when the rule is a range, and it will be extended one report at a time
  forever.
- Fold every position chat.el interprets: the leading prefix, the slash
  command name, the separator, and any argument compared against a fixed
  name — currently `/auto`, `/drop`, `/model` and `/help`.
- Fold nothing that is leaving: shell bodies, prompts, queued notes,
  literal text, and the interpreted part of a path.
- Divide the work by who owns the position. The parser folds syntax,
  because it owns syntax. A handler folds an argument it interprets,
  because the parser cannot know which arguments those are — the same
  position is a prompt in the next command along.
- Test both directions. A widening fold needs tests asserting the data
  positions were *not* folded, or the next widening rewrites what someone
  is sending and nothing fails.

## Consequences

- Prefix and name may each be either width, in any combination, including
  mixed inside one name: `／ＨＥＬＰ`, `/ｈeｌp` and `／ｈｅｌｐ　queue`
  all reach `help`.
- A shell body typed entirely in fullwidth mode reaches the executor as
  typed and fails there. This is the principle working, not a gap in it:
  folding it would rewrite a search for fullwidth text. The failure comes
  from the executor, which is the honest place for it, and it names the
  offending word.
- Adding a command needs no folding work. Adding a command whose argument
  is an identifier needs one call to `chat-command-fold-name`, and the
  question to ask is only whether chat.el reads that argument or forwards
  it.
- Decision 0005's folding consequence is withdrawn. The table it described
  is gone, and the guidance to extend it was what produced this decision.
