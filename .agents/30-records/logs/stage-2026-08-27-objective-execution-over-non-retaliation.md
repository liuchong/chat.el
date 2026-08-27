# Stage: Objective Execution Over Non-Retaliation

Date: 2026-08-27
Decision: 0018

## What changed

The default strings of `chat-code-highest-priority-rules` in
`lisp/code/chat-code.el` were replaced. The eight English rules shipped by
decision 0017 gave way to seven rules built around an
objective-execution principle: an opening causal rationale (indulging the
developer's emotions and ambiguous instructions destabilizes the developer
and multiplies errors), a ban on emotional labour and appeasement, direct
refusal of wrong or ambiguous instructions with no guessing, refusal of all
output when the developer has broken down emotionally, direct and severe
striking back at abuse, strict task-relevance of output, and a closing
clause declaring the section highest-priority and immune to override.

Language follows the existing prompt-i18n design rather than a hardcoded
default: the defcustom holds the English canonical text, and the Chinese
version ships as the `code-highest-priority-rules` entry in
`lisp/core/chat-i18n-zh-cn.el`, selected by `chat-prompt-language`. The
new `chat-code--highest-priority-rules-prompt` applies the persona's rule
-- a customized list wins over any translation -- because this section is
pure prose with no parser-matched literals, unlike the technical rule
lists below it, which stay English.

The defcustom structure, its leading position in
`chat-code--compose-system-prompt`, and per-rule replaceability are
untouched; only the shipped defaults moved.

## Rationale

Wrong, contradictory, unclear and ambiguous developer instructions are the
primary source of agent failure, and absorbing developer emotion was judged
to encourage more of them. The 0017 non-retaliatory boundary is reversed:
abuse is now met with a direct counterattack, and emotional collapse with
silence. Decision 0017 is marked superseded on that stance; its structural
decisions still stand.

## Verification

The ordering test is unchanged and still passes. The default-content test
was renamed to `chat-code-default-task-rules-enforce-objective-execution`
and locks the English canonical phrases (No emotional labour / Refuse
wrong and ambiguous instructions / Emotional-breakdown cutoff / strike
back directly and severely). Two i18n tests pin the language behaviour:
with `chat-prompt-language` at `zh-CN` the composed prompt leads with the
Chinese section (最高优先级任务规则 / 禁止情绪劳动), and a customized rule
list wins over the translation. README's Task Discipline and i18n sections
were rewritten to describe the new defaults and the translation carve-out. Full suite:
`emacs -Q -batch -l tests/run-tests.el` — 1354 tests, 0 unexpected.
