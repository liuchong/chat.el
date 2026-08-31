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
