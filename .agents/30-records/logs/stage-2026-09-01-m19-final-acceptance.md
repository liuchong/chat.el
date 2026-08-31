# M19 Final Acceptance

- Date: 2026-09-01
- Scope: M19 programming capability reliability
- Current implementation: `049c4ef454101fcb15acb34e72bf85ea7807cf7f`
- Frozen baseline implementation: `e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`
- Provider/model: `deepseek/deepseek-v4-flash`
- Verdict: passed

## Immutable Evidence

The strict final result is
`eval-20260831T183922445160000-bab276` under
`~/.chat/evaluations/m19-final-049c4ef/`. It records scenario
`acceptance/m19`, status `passed`, and 53/53 passing checks.

The four campaign identities are:

- core baseline: `m19-baseline-deepseek-v4-flash-049c4ef-r1`, 150/150;
- core current: `m19-current-deepseek-v4-flash-049c4ef-r1`, 150/150;
- large-repo baseline: `m19-large-repo-baseline-deepseek-v4-flash-049c4ef-r1`, 5/5;
- large-repo current: `m19-large-repo-current-deepseek-v4-flash-049c4ef-r1`, 5/5.

The core campaigns share one 30-task manifest and exact stable model identity,
but use distinct configuration digests and implementation revisions. Every
trial has trusted first-request usage and exact transport request identity.
There are no cleanup failures. One baseline trial correctly failed scope
checking after creating an undeclared file; current has zero scope failures.

## Capability Result

The frozen M9 implementation passed 13/150 valid trials (8.67 percent):

| Language | Passed | Failed | Timed out |
|---|---:|---:|---:|
| Emacs Lisp | 0 | 12 | 18 |
| Go | 3 | 12 | 15 |
| JavaScript | 5 | 11 | 14 |
| Python | 3 | 13 | 14 |
| Rust | 2 | 15 | 13 |

The current implementation passed 150/150 (100 percent), including 30/30 in
each language. Baseline used 1,442 model requests, 694 tool calls and 626 tool
errors. Current used 1,621 requests, 2,101 successful or attempted tool calls
and 29 tool errors. The higher request count reflects a complete staged
workflow; it replaced repeated ineffective tool failures and timeouts.

Core first-request input-token median fell from 1,921.5 to 1,327.5. The
dedicated 10,000-file `python-locate` campaigns preserved all ten trusted usage
samples: baseline passed 0/5 and current passed 5/5, while the median fell from
1,869 to 1,275, a 31.8 percent reduction. Correctness remains an independent
gate; failed baseline tasks were retained as valid performance samples.

## Deterministic Gates

All records were produced on a clean current implementation revision:

- runtime reliability: 9/9 gates passed, with 20 Goal projection samples;
- quality reliability: 20/20 gates passed;
- canonical suite: 1,925/1,925, zero skipped and zero unexpected;
- first-request footprint: 4,534 bytes versus the frozen 6,324-byte baseline,
  ratio 0.717 against the 1.10 limit;
- 10,000-file benchmark: main-loop slice 27.98 ms, warm query p95 121.36 ms,
  context-build p95 1.07 ms.

Semantic definition accuracy, reference precision/recall and Top-5 hit rate
were all 100 percent in the deterministic corpus. Editing safety,
verification, isolation, scoped instructions, context continuity, Plan/Goal,
review and collaboration scenario groups all passed their exact directed
checks. Review critical/high recall was 100 percent and formal precision was
87.5 percent.

## Replayable Lessons

1. Freeze product and harness revisions before live qualification. Any product
   change invalidates the current campaign; a harness change needs an explicit
   ownership and protocol review.
2. Preserve infrastructure attempts outside the formal repetition/task matrix.
   Resume only missing identities after validating the immutable descriptor.
3. Compare performance from valid trials independently of correctness. A failed
   judge does not erase trusted provider usage, while a provider failure before
   admissible work must never consume a trial identity.
4. Require transport-observed provider, concrete model and request IDs for every
   real request. A configured model name is not execution evidence.
5. Treat canonical skips as non-passing. The first run produced two Rust skips
   because the process `PATH` omitted the installed rustup directory. Adding
   the verified toolchain path made the same unmodified revision pass 1,925/1,925;
   no result or test was weakened.
6. Keep large-repository evidence revision-bound. Older focused campaigns were
   complete but belonged to another current revision, so fresh 1-by-5 pairs
   were required.
7. Let the final aggregator read complete raw records and recompute every gate.
   Hand-copied summaries are useful for reporting but are not acceptance proof.

M19 is complete. Later product changes require their own focused and canonical
verification; they do not retroactively alter this revision-bound result.
