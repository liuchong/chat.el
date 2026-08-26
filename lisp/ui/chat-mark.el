;;; chat-mark.el --- Glyphs for modes and providers -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; The marks that say, at a glance, what the line under the cursor will do
;; and which provider it will reach.  A glyph is read faster than a word,
;; which is the only reason to have one; decoration that has to be read is
;; just a narrower word.
;;
;; Everything here is a pure function of a symbol: a mode or a provider
;; goes in, a glyph and a face come out.  Nothing reads a buffer or a
;; session, so the table can be tested by itself and the caller decides
;; where a mark is drawn.
;;
;; Three decisions are worth stating, because each rules out an approach
;; that looks easier:
;;
;; No emoji.  They are double-width, they depend on a colour font, and the
;; same code point is a different picture on each platform, so they do not
;; line up in a monospaced buffer and cannot be recoloured.  Recolouring
;; is not optional here: a brand colour has to follow the background from
;; light to dark, and only a face can do that.
;;
;; No icon font.  `nerd-icons' and its kin need the user to have installed
;; a patched font, look right when they have and show tofu when they have
;; not, and there is no reliable way to tell the difference.  Monochrome
;; Dingbats are in almost every monospaced font already.
;;
;; A brand colour belongs to its brand.  These faces are for provider
;; marks and nothing else; using one for a part of chat.el's own interface
;; would be claiming a trademark as a theme colour.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup chat-mark nil
  "Glyphs standing for modes and providers."
  :group 'chat)

;; ------------------------------------------------------------------
;; Faces
;; ------------------------------------------------------------------

(defface chat-mark-assistant
  '((((background light)) :foreground "#96650D")
    (((background dark)) :foreground "#E0A63C"))
  "Face for the generic assistant mark.

The platform's own accent rather than any provider's, because this mark
is what stands there when no provider can be named."
  :group 'chat-mark)

(defface chat-mark-shell
  '((t :inherit shadow))
  "Face for the shell mark.

Deliberately quiet.  Shell mode is the mode where a wrong keystroke runs
something, so the mark has to be legible, but it is not a brand and has
no business competing with one."
  :group 'chat-mark)

(defface chat-mark-queue
  '((t :inherit shadow))
  "Face for the queue mark."
  :group 'chat-mark)

(defface chat-mark-brand-kimi
  '((((background light)) :foreground "#008FE8")
    (((background dark)) :foreground "#3FA9FF"))
  "Face for the Kimi family of providers."
  :group 'chat-mark)

(defface chat-mark-brand-claude
  '((((background light)) :foreground "#D97757")
    (((background dark)) :foreground "#E88B66"))
  "Face for Claude."
  :group 'chat-mark)

(defface chat-mark-brand-deepseek
  '((((background light)) :foreground "#4D6BFE")
    (((background dark)) :foreground "#7C93FF"))
  "Face for DeepSeek."
  :group 'chat-mark)

;; ------------------------------------------------------------------
;; Displayability
;; ------------------------------------------------------------------

(defun chat-mark-displayable-p (glyph)
  "Return non-nil when GLYPH can be shown on the current frame.

A mark that comes out as a hollow box is worse than no mark: it carries
nothing, takes a column anyway, and reads as a broken program."
  (and (stringp glyph)
       (not (string-empty-p glyph))
       (cl-every #'char-displayable-p (string-to-list glyph))))

;; ------------------------------------------------------------------
;; Mode marks
;; ------------------------------------------------------------------

(defconst chat-mark-mode-marks
  '(("cmd"   . ("\u276F" . chat-mark-shell))
    ("queue" . ("\u2261" . chat-mark-queue)))
  "Marks for the commands that can hold plain input, by name.

`\u276F' is the prompt glyph a modern shell draws; `\u2261' reads as a stack of
queued lines.

Two absences are deliberate.  A command that resets the default returns
the line to the baseline as soon as it has run, so it never holds the
prompt, and a mark for it would describe a state that cannot exist.  And
the assistant is not here because in that mode the provider's own mark
stands in its place -- see `chat-mark-for-provider'.")

(defun chat-mark-for-mode (name)
  "Return (GLYPH . FACE) for the command NAME, or nil when it has no mark.

Returning nil is a supported answer, not a failure: a command with no
mark gets the prompt as it was before marks existed."
  (cdr (assoc name chat-mark-mode-marks)))

;; ------------------------------------------------------------------
;; Provider marks
;; ------------------------------------------------------------------

(defconst chat-mark-provider-marks
  '((claude . "\u2733")
    (openai . "\u274B")
    (grok . "\u2715")
    (gemini . "\u2727"))
  "Providers whose logo has a widely available equivalent character.

Only these four are listed, and the list is short on purpose: each of
these characters genuinely resembles the mark it stands for -- an
eight-spoked asterisk for Anthropic's star, a multiplication sign for
x.ai, an eight-teardrop asterisk for OpenAI's knot, a four-pointed star
for Gemini's.  Every other provider gets the initial of its display name
instead of a symbol invented to fill the row.")

(defconst chat-mark-provider-faces
  '((kimi . chat-mark-brand-kimi)
    (kimi-code . chat-mark-brand-kimi)
    (kimi-code-anthropic . chat-mark-brand-kimi)
    (claude . chat-mark-brand-claude)
    (deepseek . chat-mark-brand-deepseek))
  "Providers with a known brand colour.

Absence means the mark inherits the surrounding text, which is the right
answer for a provider whose colour we do not know: an invented brand
colour is a wrong fact stated confidently.")

(defconst chat-mark-assistant-glyph "\u2726"
  "The mark for an assistant whose provider cannot be named.

The four-pointed star every tool now uses for this.  Shown only when
there is no provider configuration to read: a provider mark and a
generic assistant mark side by side would be two glyphs saying the same
thing, so the provider's mark takes the place of this one rather than
following it.")

(defun chat-mark-provider-initial (display-name)
  "Return the uppercase initial of DISPLAY-NAME, or nil when there is none."
  (when-let* ((name (and (stringp display-name) (string-trim display-name)))
              (_ (not (string-empty-p name))))
    (upcase (substring name 0 1))))

(defun chat-mark-for-provider (provider &optional display-name)
  "Return (GLYPH . FACE) for PROVIDER, named DISPLAY-NAME.

GLYPH falls back through the listed character, the initial of the display
name, and finally the generic assistant mark, so there is always
something to draw.  FACE is nil for a provider with no known brand
colour, meaning the mark inherits whatever it is drawn in -- except for
that last fallback, which is the platform's own mark and carries the
platform's own accent."
  (let* ((listed (cdr (assq provider chat-mark-provider-marks)))
         (initial (chat-mark-provider-initial display-name))
         (glyph (or listed initial chat-mark-assistant-glyph)))
    (cons glyph
          (or (cdr (assq provider chat-mark-provider-faces))
              (and (not listed) (not initial) 'chat-mark-assistant)))))

(provide 'chat-mark)
;;; chat-mark.el ends here
