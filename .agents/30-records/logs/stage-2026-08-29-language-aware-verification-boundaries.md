# Language-Aware Verification Boundaries

Date: 2026-08-29

## Scope

This stage turns one repeated live failure pattern into a narrow implementation
change. It does not claim to complete the full language-profile or prompt-pack
system. The universal Agent loop remains language-independent.

## Evidence

The immutable diagnostic campaign
`m19-current-deepseek-v4-flash-20260829T095121Z` ran revision `26e7738` over
30 tasks with five repetitions each:

- 150/150 terminal results;
- 143 passed and 7 cancelled;
- all 7 cancellations reached the approximately 120-second task budget;
- trusted provider token usage was present for 150/150 results;
- weak cells were Go and Python multi-file at 3/5, then Emacs Lisp multi-file,
  Go failing-test and Python failing-test at 4/5.

Detailed traces showed completed source edits and successful targeted tests
before the timeout. The Guard then treated a static command-list refusal as if
the build sandbox were absent. The Agent moved Go or Python caches into the
project, noticed those generated files, and spent the remaining budget trying
to remove them through additional approvals and tool errors.

The execution backend already enforced a different reality: project-scoped
writes, a private temporary `HOME/TMPDIR`, denied network access, required
process-tree cleanup, and fail-closed startup when that boundary was
unavailable. The Guard did not receive those facts.

## Changes

1. Guard payloads for build-backed tools now include the execution boundary
   enforced by the system. Static command-gate refusal is explicitly labeled
   as list-membership evidence rather than proof that isolation is absent.
2. Tool guidance now prefers a deterministic verification plan and run after
   edits. An exact compile task is the fallback for a missing check. The Agent
   is told not to relocate or clean isolated caches unless they are tracked or
   the user requested it.
3. Verification detection now composes all recognized ecosystems instead of
   stopping at the first manifest. Step IDs are language-namespaced, sorted
   deterministically and required to be unique.
4. Conventional top-level Python, JavaScript and Emacs Lisp tests receive
   argv-only checks even without a project manifest. Go and Rust checks keep
   their explicit ecosystem identities.
5. The active plan now defines the future language profile, the distinction
   between repository/current/target/planned languages, and the boundary
   between hard checks, soft prompt packs and toolchain adapters.

## Verification

- focused verification module suite: 17/17 passed before the final duplicate
  JavaScript identity case was added;
- final canonical batch: 1824/1824 passed with zero unexpected results; this
  includes the Guard boundary, polyglot composition, conventional language
  checks, duplicate rejection and multiple JavaScript entrypoint cases;
- `git diff --check` passed.

## Lessons

- Guard decisions must use measured execution facts. A static allowlist is a
  fallback policy signal, not a description of the runtime sandbox.
- Generated caches inside the source tree can turn a successful edit into a
  cleanup loop. Isolated tool homes should stay outside the audited source
  scope and their lifecycle should be owned by the backend.
- Language specialization is useful only when its scope and evidence are
  explicit. Repository language, current buffer language and requested output
  language answer different questions.
- Polyglot detection must compose. A first-match branch silently drops required
  checks and makes aggregate metrics misleading.
- A heuristic should not enter the default prompt after one anecdote. Repeated,
  reproducible evidence decides whether it becomes a hard check, a soft prompt
  rule or a project-scoped instruction.

## Follow-Up

Run one Go multi-file and one Python multi-file live smoke on the committed
candidate. Inspect tool count, approvals, Guard rationale, cache paths and task
duration, not only pass/fail. If the loop is gone, preserve the smoke evidence
and continue with the remaining goal work before freezing the final M19
campaign revision.
