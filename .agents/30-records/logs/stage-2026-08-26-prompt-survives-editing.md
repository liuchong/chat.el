# Stage: The Prompt Survives Editing

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: prompt, input-area, shell, read-only, recovery

## What Was Asked

In `cmd` mode, pressing RET deletes the prompt, and afterwards it never
refreshes back.

## What Was Actually Wrong

Two separate omissions, and the report names both halves.

The prompt is ordinary buffer text, drawn just before the input marker, in
the region the reader types in. Nothing protected it, so any edit that
reached back past the start of the input took it — backspace at column
zero of the input, a kill that went one line too far, a completion UI
replacing a region it had measured wrongly. There is no single trigger to
find, which is why looking for one was a waste: the surface was open to
all of them.

The second half is the one that made it a defect rather than a nuisance.
Nothing on the send path drew the prompt. `chat-ui--render-input-prompt`
existed and ran only when the claim changed, so an intact prompt was
redrawn and a missing one was not. Reopening the session was the only
recovery, which is exactly the "never refreshes back" in the report.

Every path was checked in batch first — plain shell lines, `cd`, `cd -`,
`!!`, empty input, slash commands, the command that releases the claim —
and every one of them kept the prompt. That result is what pointed at the
right defect: the loss does not come from the send path, so the send path
is not where to look for a cause. It is where the repair belongs.

## The Fix, Both Halves

The prompt carries `read-only`, `front-sticky (read-only)` and
`rear-nonsticky t`. This is what every shell in Emacs concluded, for the
same reason. The stickiness matters as much as the protection: without
`rear-nonsticky`, `self-insert-command` inserts with inheritance and the
first character typed would come out read-only, making the input area
unusable — a far worse bug than the one being fixed. The three properties
were verified against a live buffer before being relied on: typing after
the prompt works and is not protected, clearing the input works,
backspacing into the prompt is refused, and the code that redraws it can
still do so under `inhibit-read-only`.

`chat-ui--render-input-prompt` is now idempotent — it compares what is
drawn against what is wanted and returns without touching the buffer when
they agree — and is called on every send. Being free in the common case is
what makes calling it there reasonable, and calling it there is what caps
the cost of a lost prompt at one RET. It runs before the input is read, so
the prompt is back on screen at the moment the reader looks for it;
repairing moves the input marker with the typed text rather than through
it, so reading the input afterwards is safe.

Recovery keys off a `chat-ui-prompt` text property rather than measuring
back from the input marker by the prompt's width. Measuring works on an
intact prompt and fails on a half-eaten one, which is the only case
recovery exists for. With the property, a partial prompt is found and
replaced, and a prompt that is gone entirely is drawn at the marker
instead of leaving nothing to key off.

`chat-mode` binds `inhibit-read-only` around the `erase-buffer` in its
body, because re-running the mode over a buffer that already has a prompt
now has to be allowed to clear it.

## Verification

1014 tests pass. Five are new: the prompt refuses to be backspaced away;
typing after it is not protected and clearing the input is not refused; a
prompt deleted outright comes back on the next send with what was typed
still reaching the shell; half a prompt is repaired rather than doubled;
and an intact prompt is left alone, with the input marker unmoved, so the
common path does not churn the buffer.
