# Stage: one /wiki command

- Type: log
- Attention: record
- Status: complete
- Scope: wiki
- Tags: wiki, commands, subcommands, cjk, tools, tests

## What This Stage Did

Took `lisp/wiki/chat-wiki.el` from four months of unreachable code to a
working feature behind one command, and fixed six defects on the way.

The surface is `/wiki <subcommand>`: `index`, `log`, `lint`, `search`,
`find`, `new`, `ingest`, `ask`. The five `/wiki-*` names are gone from
`chat-commands-help` and from its Chinese translation, where an earlier
stage had faithfully translated them and so made the same false promise
twice.

## Why It Was Not Merely Dormant

The five commands had no handler wired in, so typing one sent it to the
model as chat text. But the file ended with a top-level `when` that called
`chat-wiki-initialize` whenever a `wiki` directory existed beside
`default-directory`, with the root itself resolved from `default-directory`
at load time. Loading chat.el wrote to disk. The test runner sets
`default-directory` to the repository root, which is why `wiki/log.md` in
the repository had a modification time from the last test run.

## Defects Fixed

Two were data corruption that nothing would have reported:

- **Frontmatter never parsed.** The block was matched with `.`, which does
  not cross newlines in an Emacs regexp, so anything with two keys — all
  real frontmatter — parsed as absent. Titles and dates fell back to
  filenames, and the raw YAML stayed in the body where it counted as
  content, which is why a page of pure headings looked written.
- **CJK titles collided.** The slug function deleted non-ASCII, so every
  Chinese title became the empty string. The second such page could not be
  created at all, since `chat-wiki-create-page` signals on collision.

Two were visible had anyone looked:

- **The index timestamp was source text.** `'(...)` where `` `(...) `` was
  meant, so `(, (chat-wiki--now-string))` went into the file. The artifact
  was committed.
- **Chinese search returned nothing.** The query was split on whitespace,
  which makes a Chinese sentence one token, matched as a substring.

Two were design gaps:

- **Ingest never involved a model.** It stamped a template and appended the
  raw file. Now it creates the page and asks, as a recorded turn, for the
  summary to be filled in through the wiki tools.
- **The templates failed the module's own lint.** They emitted `Key
  takeaway 1` and `[[entity1]]`, and lint flagged bodies matching
  `TODO\|FIXME\|stub\|placeholder` and links with no target. Templates now
  emit empty sections and no links, and emptiness is measured as content
  remaining once headings are removed.

## Decisions Recorded

Decision 0015. The two that will outlive this stage:

The subcommand is syntax and its argument is data — decision 0014 applied
one level down. `/wiki ｓｅａｒｃｈ 预算` folds the verb and leaves the
query alone, and there are tests in both directions.

The model reaches the wiki through `wiki_search`, `wiki_read` and
`wiki_write`, not through an index in the system prompt. That is the
opposite of `chat-knowledge.el` and the reason is the growth bound: a
knowledge store is bounded by what runs learn, a wiki is meant to grow for
years, and a growing block in the fixed region of the context is the
failure the context budget exists to prevent. `wiki_search` returns titles
and never bodies for the same reason.

## Verification

945 tests passing, up from 889; 56 of the new ones are the wiki's first.
They are weighted towards what was broken: CJK slugs and CJK search,
frontmatter across lines, the log that rewrote itself whole and left a
`log.md~` each time, templates against the lint that judges them, and the
fold boundary in both directions.

Byte-compile clean in every file this stage touched.

Smoke-checked end to end outside the suite: `/wiki`, `/ｗｉｋｉ` and
`/知识库` all resolve to `chat-wiki-dispatch`; the three tools register;
a Chinese question finds a Chinese page; the index carries a real
timestamp; and loading chat.el leaves the root untouched.

`chat-test--unimplemented-slash-commands` is empty for the first time, and
its docstring now says so is the intended state.

## Cleanup, Same Stage

Five wrappers with no caller but `M-x`, each duplicating a subcommand, are
deleted: `chat-wiki-query` and its `*Wiki Query Result*` buffer,
`chat-wiki-query-interactive`, `chat-wiki-lint-interactive`,
`chat-wiki-ingest-file`, `chat-wiki-create-page-interactive`. Also
`chat-wiki-page-exists-p`, whose only callers were in the lint that was
rewritten. `chat-wiki-show-backlinks` stays: it acts on the page in the
current buffer, which the chat surface has no equivalent for.

Lint is one scan instead of three walks plus a full walk per page inside
the orphan check. `chat-wiki--scan` reads each page once and carries its
links along; the checks run off two hash tables. A test counts reads and
asserts three pages cost three, so it cannot drift back.

Backlinks match on slugs, the same way every other link resolution works.
Searching for the literal `[[Title]]` had the lint and the page lookup
disagreeing about a page's name.

## Four More, Found By Those Tests

The wikilink pattern's character alternative was `[^\]]`. A backslash is
not an escape inside one in an Emacs regexp, so it read as "any character
except backslash followed by a literal bracket" and matched nothing anyone
would write. Link extraction returned the empty list every time it was
ever called, which silently emptied backlinks, orphans and broken links —
the linking half of a wiki, and most of the reason to have one. It hid
because an empty issue list looks exactly like a clean wiki.

`chat-wiki-create-page` wrote caller-supplied content verbatim and only
put frontmatter on pages it built from a template, so every page created
with a body — every page the model writes, every ingest — had no title and
no type. The rule existed, but in the `wiki_write` tool, which covered the
model and not the module. It now lives in `create-page`, the one door.

`chat-wiki-read-page` called `match-string` after a `string-match` that
may not have matched. Match data survives a failure, so the title came
back as a slice of the body at offsets from an unrelated string. This is
what made it visible: a page whose title read `及为什么要`, a fragment of
its own prose.

Emptiness was counted in characters, and a CJK character carries roughly
what a short word does, so the threshold was a sentence in English and a
paragraph in Chinese. Counted in `chat-wiki--tokenize` units now.

None of these five were reachable from the 42 tests, because the test
helper hand-wrote its own frontmatter and so never exercised the ordinary
path. An end-to-end run in Chinese found all of them in one go, which is
the argument for running the thing rather than only testing it.

## Left Undone

Nothing on the wiki. Dates already lost to the frontmatter bug stay lost;
that fix stops the loss and cannot recover a title that had already fallen
back to a filename.
