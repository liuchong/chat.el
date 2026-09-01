# Model-Adaptive Reliability

- Status: accepted design
- Scope: model runtime, coding Agent, evaluation
- Owners: model runtime, Agent policy, coding Eval

## 1. Purpose

Model behavior varies across providers, concrete model revisions, languages and
task shapes. The product must absorb that variation without weakening task
correctness, hiding failures or turning the Agent loop into model-name branches.

Reliability therefore has two ordered layers:

1. a provider-neutral reliability layer that every model must satisfy;
2. an evidence-backed adaptation layer that may tune how one concrete model is
   prompted, equipped and verified.

The adaptation layer improves the route to the same acceptance result. It never
changes the meaning of success, grants additional authority or suppresses a
failed gate.

## 2. Identity And Evidence

An adaptation key is the tuple:

```text
provider + concrete model + protocol + capability snapshot + language set + task category
```

Aliases are not accepted as concrete model identity. Every measurement records
the resolved model returned by the provider when available. Provider
availability attempts are classified separately from admissible model trials;
DNS, TLS, connection, rate-limit, quota, capacity and service failures do not
become evidence that a model cannot program.

Provider and concrete model are immutable fields of one Agent Run. They are
resolved once before dispatch, persisted in the Run and forced into every
initial, retry, tool-follow-up and steering request. Configuration reloads,
profile overlays and request-option hooks cannot change them. Each transport
start emits its actual provider, model and request id; missing evidence or a
mismatch invalidates the trial before its behavioral result is considered.

Evidence is eligible to change policy only when it is:

- produced by a committed, versioned fixture and deterministic judge;
- bound to a clean implementation revision and immutable campaign identity;
- repeated enough to distinguish a pattern from one stochastic result;
- reported by language and task category, not only as an overall average;
- accompanied by counterexamples, token and latency cost, and a removal rule.

One transcript may open an investigation. It cannot create a permanent model
rule.

## 3. Provider-Neutral Layer

The common layer owns all non-negotiable behavior:

- scoped authority, approval, path boundaries and checkpoint semantics;
- structured context, Goal, plan, TODO and work-note continuity;
- typed tool contracts and explicit tool errors;
- capability-declared reasoning continuation across every multi-step request;
- stale-write detection, deterministic verification and cleanup;
- bounded step, request, time, retry and repair budgets;
- honest completion: blocked permissions and failed writes are surfaced directly;
- infrastructure quarantine before an admissible trial exists;
- immutable evidence, exact identities and strict acceptance thresholds.

Retries in this layer are bounded and classified. A model-quality retry must
change at least one relevant condition, such as supplying missing evidence,
selecting a more precise tool, narrowing verification or correcting a malformed
contract. Repeating the same request shape after a semantic failure is not a
strategy. Transport retries may repeat the same payload only for the explicitly
classified transient conditions covered by the transport policy.

The Agent also measures semantic progress independently of model identity. A
successful project mutation or verification resets its no-progress state.
Coordination-only mutations such as creating a Plan do not prove task progress.
After a tool error, six inspection calls without a successful mutation or
verification append one request-only recovery instruction that requires a
precise corrective action, a different tool or an explicit blocker. Twelve such
calls terminate the Run with an explicit stagnation reason instead of consuming
the outer timeout. Repeated reads of one semantic target receive the same
warning even when no tool error preceded them. Once either warning has been
issued, twelve further inspections without observable progress terminate the
Run. Distinct inspection targets before a warning remain valid bounded research.

Direct file writes count as progress only when the checkpoint observes a state
change relative to that path's immediately preceding captured or owned state. A
successful no-op replacement is an inspection, not progress, and cannot clear a
stagnation warning. A later real mutation or successful verification clears the
warning and records recovery. Opaque execution without precise path ownership
retains its existing conservative classification.

Progress reminders are never persisted as conversation messages and retain no
tool arguments or output. Detection, recovery and stop are structured Agent
events. Evaluation records expose their counts so an apparent pass cannot hide
an expensive inspection loop and a timeout can be distinguished from a bounded
stagnation stop.

Cross-provider correctness campaigns use one provider-neutral task timeout.
Observed latency and request count remain model-separated performance facts.
A timeout window that consistently terminates one exact model before mutation
is a corpus-design bias to correct in the common layer, not evidence for a
provider-specific success threshold.

## 4. Adaptation Layer

Adaptation is declarative data resolved after the common layer. An adaptation
record may adjust only these levers:

- bounded prompt guidance and examples;
- initial and stage-activated tool advertisement;
- context allocation within the common budget;
- verification ordering and intensity;
- malformed-call repair hints and retry eligibility;
- per-stage step or request budgets within global ceilings.

It may not change authority, allowed paths, approval requirements, judges,
success thresholds, cleanup rules or evidence requirements. The generic path
must remain complete when no adaptation matches.

Records are versioned and contain:

```text
id, state, provider, model, protocol, capability digest,
language/task applicability, evidence campaign IDs, sample count,
confidence and observed effect, added token/latency cost,
policy payload, created revision, review date, removal condition
```

`state` is one of `candidate`, `active`, `retired` or `rejected`. Unknown,
expired or capability-mismatched records are ignored, not guessed. Active rules
must be removable without changing persisted session semantics.

## 5. Language Signals

Language adaptation uses four distinct signals:

- repository languages discovered from committed files and project metadata;
- current-file language;
- requested output language inferred from the task and target paths;
- planned project language stated in accepted project context.

Each signal carries provenance and confidence. Filename-only detection cannot
activate a destructive hard rule. Conflicts remain explicit in structured
context and can request clarification when they affect the result.

Deterministic language facts belong in code: syntax checks, generated paths,
toolchain discovery, targeted test commands and cleanup. Repeated strategy
guidance belongs in a small prompt pack. Project conventions remain scoped
project instructions. The main Agent loop does not fork by programming
language.

## 6. Qualification Matrix

The initial cross-provider qualification matrix is:

| Provider | Concrete model | Purpose |
|---|---|---|
| DeepSeek | `deepseek-v4-flash` | primary core comparison and transport behavior |
| Kimi Code | `k3-256k` | independent provider/protocol behavior and adaptation comparison |

`k3` is explicitly excluded from this matrix. A campaign request for Kimi must
record the exact model `k3-256k`; an alias or resolved model mismatch makes the
campaign invalid. The live qualification runner rejects a known provider/model
mismatch before readiness or any other provider request. DeepSeek qualification
likewise requires the exact `deepseek-v4-flash` identity.

Reasoning continuation is a transport fact in the common layer, not a prompt
adaptation. Each concrete model declares whether its recorded reasoning is
replayed on tool-call assistant messages only or on every assistant message.
When replay applies, field presence is mandatory even if the model returned no
reasoning text; the adapter emits an empty value rather than omitting the field.
Unknown continuation shape authorizes no provider-specific request field. A
provider rejection caused by missing required continuation invalidates the run
as a common transport defect; it is not counted as stochastic model failure.

For each provider/model pair, run the same immutable core manifest and report:

- passed, failed, cancelled and timed-out admissible trials;
- quarantined provider attempts separately;
- results per language and task category;
- first-request, final-request and total usage with coverage;
- request count, latency distribution, scope and cleanup violations;
- bounded tool-name histograms that expose successful no-progress loops without
  retaining tool arguments or results;
- stagnation detection, recovery and stop counts;
- malformed tool calls, repair attempts and unchanged retries;
- which common or candidate adaptation policy was active.

The first exact-identity M21 control at the historical 120-second digest
produced 29/30 for DeepSeek and 25/30 for Kimi. All requests retained the exact
declared identity and every workspace stayed in scope and cleaned. DeepSeek's
one failure followed a string-encoded changed-file argument and a blocked work
plan. Four of Kimi's five failures were pure pre-mutation timeouts; the fifth
combined an unknown Evidence ID with the same deadline. These observations
justify two common-layer corrections: native structured tool arguments with
recoverable Evidence errors, and a shared 300-second correctness window. They
do not justify an active model-specific rule. The committed six-task recovery
smoke must pass both models before a full `coding-core-v2` qualification.

The subsequent `coding-core-v2` qualification fixed both providers to clean
revision `a7baa43`, one manifest digest and the shared 300-second correctness
window. DeepSeek and Kimi each passed 30/30, with every language at 6/6 and
every task category at 5/5. Exact request identity, runtime verification
contracts, scope, stale-write, plan completion and cleanup gates all passed.
This closes the common-path correctness qualification without an active
adaptation.

The remaining differences are descriptive candidates, not policy triggers.
DeepSeek was faster but recovered from five tool-call or plan-sequencing errors.
Kimi used fewer requests, tool calls and tokens with no tool errors, but had
higher median and tail latency and created plans for five read-only tasks. The
current evidence does not isolate a causal lever that improves either pattern;
therefore no provider-specific rule is promoted. A future candidate still
requires same-model A/B evidence under the promotion contract in Section 7.

Cross-provider results diagnose portability. They are not pooled to hide one
provider/model failure, and one provider's baseline cannot serve as another's.

## 7. Promotion And Rollback

1. Reproduce the symptom with a fixed task and classify infrastructure, model,
   prompt, tool, verifier, permission or fixture cause.
2. Prefer a common-layer correction when the contract is wrong for every model.
3. Create a candidate adaptation only when the behavior is specific and
   repeated.
4. Run an A/B campaign with the same provider/model snapshot, manifest and
   repetition count.
5. Promote only when correctness or reliability improves without a safety
   regression and the measured token/latency cost is accepted.
6. Retire the rule when the concrete model or capability snapshot changes,
   evidence ages out, or a new campaign shows no benefit.

Rollback selects the previous declarative policy set. It does not require a
session migration or a second Agent implementation.

## 8. Acceptance

- The common path passes all deterministic safety and correctness gates with no
  adaptation loaded.
- An unmatched or stale adaptation has no behavioral effect.
- Exact provider/model/capability identity is persisted and visible in records.
- Every real request in a trial matches the Run identity; missing or mismatched
  request evidence makes the trial invalid.
- Infrastructure attempts never alter model success rates.
- A candidate and control campaign can be compared without changing fixtures or
  acceptance thresholds.
- No adaptation can expand authority or convert a failed judge into success.
- A recoverable tool error or repeated same-target inspection followed by
  inspection churn receives bounded common recovery guidance and cannot run
  until the outer timeout without an explicit stagnation outcome.
- A direct write that leaves every target unchanged cannot reset progress state;
  a subsequent observable mutation can.
- Language and task-category regressions remain visible independently.
- DeepSeek `deepseek-v4-flash` and Kimi Code `k3-256k` both pass readiness and a
  bounded core campaign before the first cross-provider policy is promoted.
