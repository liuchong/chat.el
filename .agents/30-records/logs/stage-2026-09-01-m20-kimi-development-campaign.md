# M20 Kimi Development Campaign

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: M20 seven-language development qualification
- Date: 2026-09-01

## Identity

- Campaign: `m20-dev-baseline-kimi-0393745-r1`
- Role: `baseline` development sample, not final baseline evidence
- Implementation: `0393745b97bb8f8870aba01c4bf96918a0cc696c`
- Provider/model: exact `kimi-code/k3-256k`
- Manifest digest: `fecacb185cd4b2d95c30f8fd62ff1e21ecae28731628fcf0045499390c7e0de0`
- Configuration digest: `bba4f18c4deef088291a0578c2a0a8bb58fb681428672011d3b1d4391ad69fae`
- Matrix: 42 tasks x 3 repetitions = 126 unique formal identities
- Toolchains include TypeScript 7.0.2 and official Clojure CLI 1.12.5.1664;
  Clojure has no alternate runner or network/cache fallback

## Result

The campaign completed with 123 PASS, 2 FAIL and 1 ERROR. Repetitions improved
from 40/42 to 41/42 to 42/42. C, Clojure, TypeScript and Zig were 18/18; C++,
Java and SQL were 17/18. All 835 normalized request records used exact
`kimi-code/k3-256k`. Final out-of-scope files, stale writes and unclean
workspaces were zero.

Request count was 1--16, median 7, p95 11 and total 835. Task duration was
9.173--253.689 seconds, median 56.028 seconds, p95 160.570 seconds and total
8,212.082 seconds. These are provider-specific descriptive measurements, not a
revision comparison.

One `c-refactor#3` stream ended with curl code 18. The runner archived it under
`attempts/`, cleaned the workspace and paused without consuming the formal
identity. Resuming the same campaign/configuration completed that identity.

## Failure Classification

1. `cpp-review#1` stopped after 16 requests because the model entered Plan Mode
   during a read-only review and left a two-item work plan active. It had no tool
   error, scope leak or dirty workspace. `cpp-review#2` and `#3` passed.
2. `java-multi-file#1` returned after one request with no tool call or file
   change, so label and documentation judges failed. Repetitions 2 and 3 passed.
3. `sql-single-fix#2` received one precise `files_replace` no-match error, then
   inspected repeatedly without a successful mutation before closing. The
   divide judge failed; repetitions 1 and 3 passed.

The fingerprints are different and none repeated on the next sample. Spec 028
and Spec 029 therefore prohibit promoting them into a hard language rule or
provider-specific policy. They remain bounded candidates for future repeated
evidence about premature completion, mode discipline and post-edit recovery.

DeepSeek's corresponding development campaign passed 126/126 while recovering
from 26 tool errors; Kimi recorded only one tool error but did not recover from
that trial and had two closure failures without a tool error. This suggests a
recovery-policy difference, not a less reliable file-tool implementation. The
final paired campaigns must preserve the common correctness contract and report
each provider separately.

## Next Gate

Freeze one historical baseline implementation and one current clean
implementation with the current harness. Run four independent 42-task-by-five
campaigns: DeepSeek baseline/current and Kimi baseline/current. Each must contain
210 unique formal identities, exact request-model evidence and separately
quarantined provider-availability attempts.

## Verification

- `completion.json` records `complete=true`, 126 formal results and 123 passes.
- The bounded audit found 126 unique identities, zero model drift across 835
  request records, zero final scope leaks, zero stale writes and zero unclean
  workspaces.
- `git diff --check` passed for the retained stage documentation.
- The canonical runner discovered 2014 tests: 2012 passed, zero were unexpected
  and two existing Rust system-SSL environment cases skipped. All four docs
  tests passed.
