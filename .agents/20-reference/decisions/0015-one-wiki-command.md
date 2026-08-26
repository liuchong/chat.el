# Decision 0015

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: wiki
- Tags: wiki, commands, subcommands, cjk, tools, context-budget

## Title

One `/wiki` with subcommands, reached by tools rather than by prompt

## Context

`chat-wiki.el` had been in the tree for four months: 887 lines, five
documented slash commands, zero tests, and no caller. Typing
`/wiki-query` sent the line to the model as ordinary chat text, because
`chat-wiki-command-handler` was never wired into the command table. The
five names lived in `chat-commands-help`, and a test allow-list existed
solely to record that they answered nothing.

Being unreachable was not the same as being inert. The file ended with

```elisp
(when (or (file-directory-p chat-wiki-root)
          (bound-and-true-p chat-root-directory))
  (chat-wiki-initialize))
```

and `chat-root-directory` was never defined anywhere, so the condition
reduced to "a `wiki` directory exists next to wherever Emacs started".
`chat-wiki-root` was computed from `default-directory` at load time.
Loading chat.el therefore created directories and wrote two files, in a
location the user had not chosen, for a feature they could not invoke.
The test runner sets `default-directory` to the repository root, so every
test run wrote into the repository.

Underneath that were four defects that no test could have missed, because
there were no tests:

- The index frontmatter used `'(...)` where `` `(...) `` was meant, so the
  literal text `(, (chat-wiki--now-string))` was written as the timestamp.
  The artifact was committed in `wiki/index.md`.
- `chat-wiki--parse-frontmatter` matched the block with `.` , which does
  not span newlines in an Emacs regexp. Frontmatter of two or more keys —
  that is, all of it — parsed as absent. Every title and date silently
  fell back to the filename, and the raw YAML stayed at the top of the
  body, where it counted as content.
- `chat-wiki--slugify` deleted `[^[:ascii:]]`. Every CJK title slugified
  to the empty string, so the first such page took the name and creating a
  second one signalled.
- Search split the query on whitespace. A Chinese question is one token,
  matched as a substring, so Chinese search returned nothing at all.

And two design gaps: `chat-wiki-ingest` did not involve a model, it
stamped a template containing `Key takeaway 1` and `[[entity1]]`; and
`chat-wiki-lint` then flagged those same pages, by grepping the body for
`TODO\|FIXME\|stub\|placeholder` — a test that a wiki about software fails
on its own subject matter.

## Decision

**One command.** `/wiki <subcommand>` replaces `/wiki-ingest` and its four
siblings. Five top-level entries for one feature crowd the completion list
that every other command shares, and a shared prefix is a namespace the
parser does not know is a namespace: it cannot complete the second half,
cannot report an unknown one usefully, and cannot localize the verb
without inventing five more aliases.

**The subcommand is syntax; its argument is data.** The verb folds from
fullwidth, matches case-insensitively and accepts a localized alias. What
follows is passed on untouched. This is decision 0014 applied one level
down, and `/wiki` is where the rule earns its keep: `/wiki search 预算`
and `/wiki ingest ~/文档.md` have a folded verb and an unfolded argument
in the same line.

**Subcommand aliases live in this module, not in `chat-i18n-aliases`.**
That table is the slash command namespace and feeds top-level completion,
where `搜索` on its own means nothing.

**The model reaches the wiki through tools, not through the prompt.**
`wiki_search`, `wiki_read` and `wiki_write`. This is the opposite of
`chat-knowledge.el`, which puts its whole index in every request, and the
difference is the growth bound: a knowledge store is bounded by what runs
happen to learn, while a wiki is meant to grow for years. A monotonically
growing block in the fixed region of the context is the failure the
context budget exists to prevent. `wiki_search` returns titles and types,
never bodies, so a search cannot put an unbounded amount of text into a
reply whose size the model did not choose.

**`chat-wiki-root` moves to `~/.chat/wiki/`** beside the session,
scratch and knowledge stores, and **nothing runs on load.** Every writer
ensures its own directory, so first use is early enough.

**Ingest asks the model.** The page is created with the document in it,
then a recorded turn asks the model to fill in the summary, entities and
concepts using the wiki tools. Recorded rather than hidden so the request
and the tool calls that answer it are both on screen.

**Lint measures content, not vocabulary.** A page is a skeleton when what
remains after removing headings and empty list markers is shorter than
`chat-wiki-prose-minimum`. The templates now emit empty sections and
invent no links, so a fresh page is honestly empty and arrives with
nothing dangling.

## Consequences

`/wiki` is one entry in `chat-ui--command-table`, and
`chat-test--unimplemented-slash-commands` is empty for the first time.
Its docstring now says the list is meant to stay empty rather than
explaining what is on it.

42 tests where there were none. They are weighted towards what was broken
rather than towards coverage: CJK slugs and CJK search, the frontmatter
that never parsed, the log that rewrote itself and left a backup each
time, templates against the lint that judges them, and the fold boundary
between verb and argument in both directions.

Existing logs read newest-last rather than newest-first, since entries are
appended. `chat-wiki-log-recent` reads from the end to match.

The committed `wiki/` directory is gone. It held the unexpanded-template
artifact and a `log.md~` left by `write-file`, both generated, and with
the root moved it was no longer the store anyway.

Dates recorded before this are still wrong on disk wherever a page was
written and read back: the parse fix stops the loss, it cannot recover
what already fell back to a filename.

One capability, one path. `chat-wiki-query` and its `*Wiki Query Result*`
buffer are deleted rather than left beside `/wiki search`, and so are
`chat-wiki-query-interactive`, `chat-wiki-lint-interactive`,
`chat-wiki-ingest-file` and `chat-wiki-create-page-interactive` — every
one of them a wrapper with no caller but `M-x`, duplicating a subcommand.
`chat-wiki-show-backlinks` stays, because it acts on the page in the
current buffer and has no equivalent on the chat surface.

Lint is one scan. `chat-wiki--scan` reads each page once and returns its
links with it; the three checks then run off two hash tables. It was three
walks of the wiki plus, inside the orphan check, another full walk per
page. A test counts the reads, so the shape cannot regress quietly.

Backlinks are matched as slugs, which is how a link is resolved
everywhere else. Searching for the literal `[[Title]]` meant the lint and
the page lookup disagreed about what a page is called, and a page linked
by its slug read as unlinked.

Frontmatter is written by `chat-wiki-create-page`, for every page, at the
one door they all go through. It used to write caller-supplied content
verbatim and add frontmatter only to pages it generated from a template —
so a page created with a body, which is every page the model writes and
every ingest, arrived with no title and no type. The rule was implemented
once in the `wiki_write` tool, which is the wrong place: it covered the
model and not the module.

Four more latent defects surfaced while testing the above, and the first
of them was the largest.

The wikilink pattern used `[^\]]` as its character alternative. A
backslash is not an escape inside one in an Emacs regexp, so it read as
"any character except backslash, followed by a literal bracket" and
matched no link that anyone would write. Extraction returned nothing,
always. Every backlink, orphan and broken-link report was therefore empty
— the linking half of a wiki, which is most of the point of one, had never
worked. It hid because the failure was silence: an empty issue list reads
as a clean wiki.

`chat-wiki-read-page` ran `string-match` for a heading and then called
`match-string` whether or not it matched. A failed `string-match` leaves
the previous match's data in place, so the title came back as a slice of
the body at offsets belonging to an unrelated string — prose fragments
where a title belongs, and a different one each time depending on what had
matched last.

Emptiness was measured in characters, which is not a comparable amount of
writing across scripts. A CJK character carries roughly what a short word
does, so forty characters is a sentence in English and a paragraph in
Chinese, and a Chinese page had to say two or three times as much as an
English one to stop being reported empty. It is now counted in the units
`chat-wiki--tokenize` already produces: words for alphabetic scripts,
characters for CJK.
