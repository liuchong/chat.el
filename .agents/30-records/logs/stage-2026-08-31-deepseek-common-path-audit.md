# DeepSeek Common Path Audit

- Date: 2026-08-31
- Scope: M21 provider-neutral qualification audit
- Implementation revision: `77e7777a97e27bdcbd5c0a5f6f4b2a83fdedaab0`
- Campaign: `m21-common-deepseek-v4-flash-77e7777-r1`
- Provider/model: DeepSeek `deepseek-v4-flash`
- Manifest digest: `0164487205a6fab51be67eebdfb9d7dad48ec7c68ccadb20b513c2da5e344dcc`
- Tags: agent, evaluation, deepseek, plan, verification

## Result

The bounded core campaign completed 30/30 valid trials and every deterministic
judge passed. No provider attempt was quarantined, no trial was cancelled, and
the 30 session wires contained zero `plan-required` events.

| Metric | Result |
|---|---:|
| Median duration | 43,744 ms |
| p90 duration | 63,484 ms |
| Maximum duration | 74,578 ms |
| Total requests | 269 |
| Median requests per trial | 10 |
| p90 requests per trial | 13 |
| Maximum requests per trial | 15 |
| Tool errors | 8 |
| Approval events | 102 |
| Total tokens | 1,687,720 |

All five languages passed 6/6. JavaScript had the largest process cost with 59
requests and four tool errors; Rust had zero tool errors.

## Error Classification

The eight tool errors were not one homogeneous model-quality signal:

- three duplicate `programming_plan_create` calls occurred because an active
  plan still advertised the creation operation;
- two `programming_verification_run` calls received Agent-private `:read-set`
  state that is outside the verification runner contract;
- one direct `node` compile request was correctly denied by the guarded approval
  policy; the denial must not be removed to improve an error count;
- one `files_grep` call supplied a directory where a file was required;
- one `apply_patch` call omitted the required `*** Begin Patch` header.

The first five errors exposed two provider-neutral defects. Active plans now
remove `programming_plan_create` from the provider menu, and verification
context is projected through an explicit allowlist before crossing the module
boundary. The approval denial remains unchanged. The directory and malformed
patch cases remain candidates for repeated cross-provider evidence; one sample
does not justify a permanent model rule.

## Verification

- capability and verification-context tests: 32/32 passed;
- canonical suite: 1883/1883 passed, zero skipped and zero unexpected;
- no campaign or test process remained running.

Because the common implementation changed after this campaign, its results are
diagnostic evidence and cannot be paired with Kimi as the final common-path
comparison. Freeze the new clean revision, rerun DeepSeek, then run exact Kimi
Code `k3-256k` with the same manifest. `k3` remains excluded.

