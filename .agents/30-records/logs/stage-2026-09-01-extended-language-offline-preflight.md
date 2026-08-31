# Extended Language Offline Preflight

- Date: 2026-09-01
- Scope: M20 complete offline fixture and campaign preflight gate
- Status: passed; exact-model mutation smoke and live campaigns pending
- Implementation revision: `d95843563433c77f97af1633b76505e02d87219d`

## Result

All seven extended-language fixtures now pass their complete no-network gate.
For Zig, Clojure, Java, TypeScript, C, C++ and SQL, the gate first normalizes
the fixture to its known-good state and then proves that the seeded divide,
label and active defects fail. This yields deterministic coverage for all 42
tasks without treating an unavailable dependency or a skipped check as model
evidence.

The extended manifest now owns a versioned `preflightChecks` entry. It runs the
complete fixture gate from the manifest directory before provider readiness.
The check has a unique identity, a bounded timeout and an argv contract; its
first executable must already be present in the campaign's versioned toolchain
record. Missing dependencies, invalid configuration, timeout or nonzero exit
blocks the campaign before any model request.

Clojure fixture verification explicitly removes Leiningen's implicit base
profile while retaining the fixture's declared project and offline repository
policy. This is a fixture-isolation rule, not a replacement for product-project
verification authority.

## Clean Revision Evidence

Both exact-model preflights ran on clean revision `d958435` against the same
42-task manifest and the same offline fixture gate:

| Provider | Model | Manifest digest | Configuration digest |
|---|---|---|---|
| DeepSeek | `deepseek-v4-flash` | `2e388e0b2ab79e0eabc416c0d50c597e9df922b7799075a31977bab9f27c52a3` | `87ef1717b06bcb95577c6b0fd4e38017b6778a6ce28866f9c53a95971b89e449` |
| Kimi Code | `k3-256k` | `2e388e0b2ab79e0eabc416c0d50c597e9df922b7799075a31977bab9f27c52a3` | `4abdcd0f38d5758c93eefeda5827a9b4aeaf4bd9acf639c5fabc7dc37082fdff` |

Each descriptor reported `clean=true`, 42 expected results and the manifest
check `extended-fixture-offline-gate`. Provider and concrete model identities
remain separate; their results must not be pooled. These were preflight-only
runs, so no model API request was made.

The captured executable identities were:

- Apple Clang and Clang++ 21.0.0;
- Java and javac 21.0.12.1;
- Leiningen 2.9.4;
- Node 26.7.0 and TypeScript 6.0.3;
- shell 3.2.57(1)-release;
- SQLite 3.51.0;
- Zig 0.16.0.

Tool version output contains only child-process evidence. Editor process
lifecycle messages are suppressed at the process boundary and cannot enter a
version identity or configuration digest.

## Verification

- complete seven-language offline fixture gate: passed;
- coding Eval suite: 55/55 passed;
- focused preflight success, missing-tool, timeout and cleanup tests: passed;
- changed Lisp files byte-compiled successfully;
- clean-revision canonical suite: 1,960/1,960 passed, zero unexpected;
- repository build artifacts after verification: zero;
- surviving verifier processes and campaign worktrees: zero.

## Replayable Lessons

1. Executable availability does not prove cached dependency availability. The
   complete offline fixture gate belongs in the manifest-level preflight before
   provider readiness.
2. A tool's default profile is an undeclared dependency surface. Fixture
   verification must remove implicit profiles when the fixture contract does
   not own them, while product verification still follows project authority.
3. Child stdout and editor process lifecycle text are different evidence
   domains. Suppress lifecycle messages at process capture instead of stripping
   known strings from recorded versions.
4. A new finding during a long goal changes the smallest affected execution
   boundary. Record the finding, repair and revalidate that boundary, preserve
   already verified milestones and continue from the current checkpoint.
5. A non-urgent new user requirement is queued and linked to the active goal;
   it does not silently replace the objective or restart the current milestone.
   An urgent requirement may reorder work, but the state change, reason,
   affected plan items and new required evidence must be explicit.
6. Clean-revision proof follows the implementation commit. Dirty-tree success
   is useful development evidence but cannot close a revision-bound gate.

## Remaining M20 Work

Run one bounded exact-model mutation smoke per added language with DeepSeek
`deepseek-v4-flash` and Kimi Code `k3-256k`. Diagnose and repair any shared or
model-specific failure before starting repeated immutable campaigns. The live
results must remain partitioned by provider, concrete model, configuration
digest and language.
