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
- canonical batch after the boundary change: 1824/1824 passed with zero
  unexpected results; this
  includes the Guard boundary, polyglot composition, conventional language
  checks, duplicate rejection and multiple JavaScript entrypoint cases;
- canonical batch after the evidence-driven plan guidance adjustment:
  1825/1825 passed with zero unexpected results;
- `git diff --check` passed.

## Focused Live Feedback

Committed revision `eb1b56f` passed campaign
`m19-smoke-go-boundary-20260829T201500` for `go-multi-file` in 44.803 seconds.
The result changed only `sample.go` and `README.md`, produced no generated or
out-of-scope files, and cleaned its workspace. The Guard allowed the original
targeted `go test` command and explicitly reasoned about the project and private
temporary environment. No cache relocation or cleanup command appeared.

The same trace exposed two unrelated plan tool errors: the model batched two
dependent transitions with one observed revision, then attempted the next item
before the prior transition was valid. Tool and prompt guidance now state that
plan transitions are serial, only one item may be active, and each next call
must use the revision returned by the previous result. This is a soft guidance
change supported by an exact trace rather than a new hard-coded exception.

Committed revision `919bc87` then passed campaign
`m19-smoke-python-boundary-20260829T203700` for `python-multi-file` in 51.641
seconds. It made 19 tool calls with zero tool errors and zero verification
retries. Only `sample.py` and `README.md` changed; generated and out-of-scope
files were empty and workspace cleanup passed. The Guard directly allowed the
original `python3 -m unittest` command. No cache, virtual-environment, cleanup
or removal call appeared, and all six plan transitions completed serially.

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

## Focused Live Feedback: 2026-08-30

Current campaign `m19-current-deepseek-v4-flash-8881b62` ran committed revision
`8881b62`. A code-18 truncated stream was archived as an infrastructure attempt;
the same campaign then resumed the missing trial and passed it without replacing
or duplicating an existing durable result.

The first complete repetition produced 29/30 passes. The only cancellation was
`go-refactor`. Its required targeted command, `go test -run ^TestNormalize$ ./...`,
passed after the intended edit. The Agent then ran `go test ./...`, encountered
the fixture's unrelated pre-existing `TestDivide` failure, reverted and reapplied
the verified edit, and exhausted the 120-second trial budget after 19 steps,
22 tool calls, three tool errors and 18 approval events. No out-of-scope file was
changed and workspace cleanup passed.

This is direct evidence for a bounded verification rule rather than a
language-specific exception:

- start with the narrowest deterministic check that covers the changed behavior;
- a broader failure blocks completion only when evidence connects it to the
  current diff;
- do not rerun an unchanged failing command or undo verified work merely to
  diagnose an unrelated failure;
- live Eval command judges are the complete targeted verification contract, so
  once those commands pass the Agent inspects the diff and finishes instead of
  adding a broader suite.

The old campaign was stopped after two additional passing trials in repetition
two. Because the prompt implementation changed, its 32 durable results remain
diagnostic evidence and the campaign must not be resumed for final acceptance.

## Follow-Up

The focused boundary regression is complete. Continue with the remaining goal
work before freezing the final M19 campaign revision; do not spend additional
provider calls on this already-confirmed path unless a later code change touches
Guard payloads, plan guidance or build execution.
