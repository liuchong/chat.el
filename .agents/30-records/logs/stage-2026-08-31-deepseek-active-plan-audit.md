# DeepSeek Active Plan Audit

- Date: 2026-08-31
- Scope: M21 provider-neutral qualification audit
- Implementation revision: `42feb05db32e3cd0ac603fbca88904666a12cc97`
- Campaign: `m21-common-deepseek-v4-flash-42feb05-r1`
- Provider/model: DeepSeek `deepseek-v4-flash`
- Manifest digest: `0164487205a6fab51be67eebdfb9d7dad48ec7c68ccadb20b513c2da5e344dcc`
- Tags: agent, evaluation, deepseek, plan, task-output

## Result

The bounded core campaign produced 29 passing trials and one cancelled trial.
The cancelled JavaScript multi-file trial reached the 120-second Agent limit
after making both requested edits and passing `node test.js label`; it spent 23
requests and 34 tool calls without closing its active plan and final response.

| Metric | Result |
|---|---:|
| Median duration | 41,967 ms |
| p90 duration | 67,260 ms |
| Maximum duration | 120,151 ms |
| Total requests | 283 |
| Median requests per trial | 9 |
| p90 requests per trial | 15 |
| Maximum requests per trial | 23 |
| Tool errors | 11 |
| Approval events | 110 |
| Total tokens | 1,714,606 |

Elisp, Go, Python and Rust passed 6/6. JavaScript passed 5/6 and contained the
single cancelled trial.

## Error Classification

The eleven tool errors separated into repeated common friction and isolated
model behavior:

- three `files_read` calls followed task summaries to internal
  `~/.chat/work/*.log` paths that the project boundary correctly refused;
- two repeated `programming_plan_create` calls occurred after create had been
  removed from the provider menu;
- two compile or patch attempts were correctly denied by the guarded policy;
- one unavailable plan update followed a completed edit path;
- one `open_file` call contained malformed input;
- one `apply_patch` call omitted the required patch header.

The common causes were contract defects. Background-task summaries exposed an
internal path that the Agent could not consume. Plan guidance was conditioned
on the create tool, so removing create also removed the transition instructions
needed to finish the existing plan. The implementation now keeps logs internal,
routes output through `programming_task_output`, and emits separate pre-create
and active-plan guidance. The guarded denials and isolated malformed calls are
not weakened or converted into provider rules from one sample.

## Disposition

This campaign is diagnostic because the common implementation changed after it
ran. Focused task-summary and plan-guidance regressions pass. Run the canonical
suite, freeze the new clean revision, then repeat DeepSeek and exact Kimi Code
`k3-256k` against the same manifest. `k3` remains excluded.

## Verification

- task-summary and active-plan guidance regressions: 3/3 passed;
- Rust execution-isolation prerequisites: 2/2 passed with the installed
  `~/.cargo/bin` toolchain on `PATH`;
- canonical suite: 1884/1884 passed, zero skipped and zero unexpected;
- no campaign or test process remained running.

## Follow-up Run On `ef24a88`

The first follow-up campaign completed all 30 trials successfully, including
the JavaScript multi-file trial that previously timed out.

| Metric | Result |
|---|---:|
| Passed | 30/30 |
| Median duration | 44,272 ms |
| p90 duration | 66,788 ms |
| Maximum duration | 82,249 ms |
| Total requests | 288 |
| Median requests per trial | 10 |
| p90 requests per trial | 16 |
| Maximum requests per trial | 18 |
| Tool errors | 6 |
| Approval events | 111 |
| Total tokens | 1,733,288 |

The internal task-log disclosure was fixed: every remaining log path occurred
only in bounded runtime lifecycle events and never in a model-visible tool
result. Three trials still attempted a second `programming_plan_create` after
the provider menu removed it. The system prompt builder accepted a Session but
did not bind that Session while deriving its textual tool menu. Native schemas
therefore used the narrowed turn menu while prompt text used the global menu.
The runtime rejection was correct, but the two model-facing contracts
contradicted each other.

The prompt now derives guidance and formatted tools from the same
session-filtered menu as native provider schemas. This changes the
implementation revision, so the successful `ef24a88` campaign remains
diagnostic. Repeat both exact-model campaigns on the new clean revision before
making provider comparisons.

Post-fix canonical verification passed 1885/1885 tests with zero skipped and
zero unexpected results. The new regression exercises a global registry that
contains both create and transition tools while the Session advertises only
transition, and proves that prompt guidance follows the Session menu.

## Follow-up Run On `4d9aa7b`

The next DeepSeek campaign used the corrected initial Session binding and passed
all 30 trials, but it exposed a second lifecycle defect after tools changed the
Session during the run.

| Metric | Result |
|---|---:|
| Passed | 30/30 |
| Median duration | 37,977 ms |
| p90 duration | 51,472 ms |
| Maximum duration | 83,203 ms |
| Total requests | 258 |
| Median requests per trial | 9 |
| p90 requests per trial | 13 |
| Maximum requests per trial | 17 |
| Tool errors | 5 |
| Approval events | 100 |
| Total tokens | 1,434,538 |

Three trials still attempted a repeated `programming_plan_create`. Only two of the
twenty created work plans reached `completed`; the other eighteen remained
`active` even though the Agent run reported completion. Native provider schemas
were already rebuilt from the current execution Session, but the textual contract
was prepared only once before the run. In addition, the execution Session is a
transient policy copy: durable Plan metadata written through it could remain absent
from the canonical in-memory Session and later be overwritten by transcript
persistence.

The provider-neutral correction therefore has three parts: rebuild tagged textual
tool guidance from the current execution Session on every request, merge successful
durable execution metadata into the canonical Session before persistence, and make
an open Plan a bounded, audited completion barrier. A run with an active Plan may
retry closure only while a tool-capable turn remains; otherwise it stops explicitly
instead of claiming success. A blocked Plan stops with its real reason.

Because this correction changes the implementation revision, `4d9aa7b` is also a
diagnostic campaign. Kimi `k3-256k` was deliberately not run on the invalidated
revision. Both exact-model campaigns restart from the next clean revision and use
the same manifest; `k3` remains excluded.

Post-correction verification passed the eight focused completion-barrier,
dynamic-contract and Session-synchronization regressions and the full canonical
suite at 1,893/1,893, with zero skipped and zero unexpected results. No provider
campaign result is claimed for the uncommitted tree.
