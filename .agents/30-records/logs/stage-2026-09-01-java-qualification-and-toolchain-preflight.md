# Java Qualification and Remaining Toolchain Preflight

- Type: `logs`
- Attention: `records`
- Status: `completed`
- Date: 2026-09-01
- Implementation revision: `6a6319e916c1b8d698f4f496cfb3a54f97db190b`

## Scope

This stage revalidated the Java focused mutation smoke after the shared
correctness window changed the manifest identity. It also preflighted the
remaining TypeScript and Clojure focused manifests before any provider request.

The Java manifest digest was
`ce69313d9e78381757e23d4e91f1057503ae9e77b779b118bd6fea651794f771`.
Both campaigns used a 300-second task window and the same clean implementation
and harness revision.

## Java Result

| Provider/model | Agent ms | Requests | Tool calls/results | Errors | Approvals | Tokens | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `deepseek/deepseek-v4-flash` | 16,856 | 8 | 9/9 | 0 | 4 | 59,364 | PASS |
| `kimi-code/k3-256k` | 68,758 | 8 | 9/9 | 0 | 4 | 52,023 | PASS |

Every real request retained the exact declared provider/model identity. Both
trials changed only `src/Sample.java`, passed the deterministic judge and
reported the same three generated class files below
`.chat-eval-build/java/`. `outOfScopeFiles` was empty and `workspaceCleaned`
was true. The new bounded diagnostics fields were present with zero errors and
zero omitted records.

Configuration digests remained provider-separated:

- DeepSeek: `3aad261527ea87ab42927fb39fd1e3ce6e22ea36e7f3a75a55d8d912beeaabd0`
- Kimi Code: `e0c647fec1b55ba590932f4fecc98f6f3e2cf8a1852cf57d4434a1de715229a4`

No Java-specific prompt or code change is justified by this sample. The shared
tool and verification contracts completed correctly for both models; latency
and token differences remain measurements, not policy branches.

## Preflight Blocks

TypeScript stopped with `Campaign judge executables are unavailable: tsc`.
Clojure stopped with `Campaign judge executables are unavailable: lein`.
Both failures occurred before provider readiness, so they consumed no model
request and do not enter model reliability statistics.

The host has no independent `tsc` or `lein` executable on its configured PATH.
A compiler binary nested inside another package's private dependency tree is
not a stable, versioned toolchain identity and was deliberately not exposed to
the campaign. The Agent did not install, copy or shim either toolchain.

TypeScript and Clojure remain `BLOCKED` until their required offline toolchains
are explicitly provisioned or the normative corpus adopts another deterministic
project-owned toolchain contract. The Java qualification remains valid and the
unrelated roadmap can continue.

## Long-Goal Lesson

Long-goal state needs both dependency status and evidence identity. A historical
Java PASS on the 120-second manifest remained useful diagnostic evidence, but it
could not close the current 300-second corpus item because the manifest digest
changed. Goal reconciliation therefore reopened only that item, reran it, and
kept the larger milestone active.

Conversely, a missing local compiler is a scoped dependency block, not a reason
to stop unrelated roadmap work or weaken the corpus. Record the blocked items,
preserve their exact prerequisites, continue independent work, and resume them
only after the external state changes.
