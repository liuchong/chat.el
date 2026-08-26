;;; chat-mark.el --- Glyphs for modes and providers -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; The marks that say, at a glance, what the line under the cursor will do
;; and which provider it will reach.  A glyph is read faster than a word,
;; which is the only reason to have one; decoration that has to be read is
;; just a narrower word.
;;
;; The table is a pure function of a symbol: a mode or a provider goes in,
;; a glyph and a face come out.  Nothing reads a buffer or a session, so
;; it can be tested by itself and the caller decides where a mark is
;; drawn.  Images are the one exception and are kept in their own section
;; at the end, because a badge has to be measured against the frame it
;; will be drawn on.
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
;;
;; An inline SVG is what those three rejections leave open, and it is the
;; only one of the four that can look like a logo.  It is not double-width
;; because its size is given in pixels, not columns; it is not a different
;; picture per platform because it is drawn here; it needs no font to be
;; installed because it is geometry; and it is recoloured on every draw
;; from the same face, so light and dark still work.  What it does need is
;; a graphical frame and a librsvg build, and where either is missing the
;; glyph underneath shows instead -- see `chat-mark-provider-image'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)

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

;; ------------------------------------------------------------------
;; Logo images
;; ------------------------------------------------------------------
;;
;; Everything below reads the frame, so it is not pure and is not part of
;; the table above.  All of it returns nil rather than a placeholder when
;; it cannot do its job: the caller draws an image over a glyph, so nil
;; means the glyph stands, which is the previous behaviour exactly.

(defcustom chat-mark-logo-directory (expand-file-name "~/.chat/logos/")
  "Where a provider's own logo file is looked for.

A file named after the provider symbol -- `deepseek.svg', `kimi.png' --
is drawn in place of anything generated here.  No logo ships with
chat.el: a vendor's mark belongs to the vendor, and a redrawn
approximation of one is a worse answer than an honest badge.  Drop the
real file in and the prompt shows the real mark."
  :type 'directory
  :group 'chat-mark)

(defcustom chat-mark-logo-enabled t
  "Whether provider marks may be drawn as images.

Set to nil to keep the glyphs.  Kept as a switch because an image in the
prompt is a matter of taste in a way that a coloured letter is not."
  :type 'boolean
  :group 'chat-mark)

(defcustom chat-mark-logo-scale 0.85
  "How much of the line height a drawn provider mark occupies.

Below 1 so the badge sits inside the line rather than setting its
height.  A mark taller than the text moves every line below it the moment
the provider changes, which turns a decoration into a layout bug."
  :type 'number
  :group 'chat-mark)

(defconst chat-mark--logo-extensions '("svg" "png")
  "Extensions accepted for a provider logo file, in order of preference.

SVG first because the prompt is drawn at whatever height the frame's font
happens to be, and only SVG is still sharp at a height nobody chose in
advance.")

(defvar chat-mark--image-cache (make-hash-table :test #'equal)
  "Images already built, keyed by everything that shapes one.

The prompt is redrawn on every send, and building an image means
rasterising an SVG, so without this the cost is paid per keystroke-worth
of redraw.  A theme change lands on a different key rather than needing
the cache cleared, because the resolved colour is part of the key.")

(defconst chat-mark--image-cache-limit 64
  "How many images to keep before starting over.

Entries are cheap and few -- a handful of providers times the themes seen
in one session -- but a cache with no bound is a leak that happens to be
slow, and this file has no business being the reason a long session
grows.")

(defun chat-mark--logo-file (provider)
  "Return the path of PROVIDER's own logo file, or nil when there is none."
  (when (and provider (file-directory-p chat-mark-logo-directory))
    (cl-loop for extension in chat-mark--logo-extensions
             for path = (expand-file-name
                         (format "%s.%s" provider extension)
                         chat-mark-logo-directory)
             when (file-readable-p path) return path)))

(defun chat-mark--escape-xml (text)
  "Return TEXT with the three characters XML cannot take literally escaped."
  (replace-regexp-in-string
   "[&<>]"
   (lambda (match)
     (pcase match ("&" "&amp;") ("<" "&lt;") (_ "&gt;")))
   (or text "")))

(defun chat-mark--contrast-colour (background)
  "Return a colour legible on BACKGROUND: near-white, or near-black.

Weighted for perceived brightness rather than averaged, because green
reads far brighter than blue at the same value and an unweighted midpoint
puts white text on a yellow badge."
  (let ((rgb (ignore-errors (color-name-to-rgb background))))
    (if (and rgb (> (+ (* 0.299 (nth 0 rgb))
                       (* 0.587 (nth 1 rgb))
                       (* 0.114 (nth 2 rgb)))
                    0.62))
        "#1A1A1A"
      "#FFFFFF")))

(defun chat-mark-badge-svg (glyph colour size)
  "Return SVG source for a SIZE-pixel badge holding GLYPH, filled with COLOUR.

Authored in a 32-unit box and scaled by the viewBox, so the proportions
are fixed once here instead of being recomputed against whatever height
the frame's font turns out to be.

Pure, and separate from `chat-mark-provider-image' so that the shape can
be checked as a string without a frame to draw it on."
  (format
   (concat "<svg xmlns=\"http://www.w3.org/2000/svg\""
           " width=\"%d\" height=\"%d\" viewBox=\"0 0 32 32\">"
           "<rect x=\"1\" y=\"1\" width=\"30\" height=\"30\""
           " rx=\"7\" fill=\"%s\"/>"
           ;; Two thirds of the box would fill it edge to edge at the
           ;; smallest height this is ever drawn at, where the inset is
           ;; the only thing separating the letter from the background
           ;; behind the badge.
           "<text x=\"16\" y=\"23\" font-size=\"19\""
           " font-family=\"Helvetica Neue,Helvetica,Arial,sans-serif\""
           " font-weight=\"bold\" fill=\"%s\" text-anchor=\"middle\">%s</text>"
           "</svg>")
   size size colour (chat-mark--contrast-colour colour)
   (chat-mark--escape-xml glyph)))

(defun chat-mark--build-image (provider glyph colour size)
  "Return an image of PROVIDER's mark, or nil when none can be made.

A logo file wins over a drawn badge for any provider, including one whose
glyph already resembles its logo: a reader who put the real mark in the
directory asked for the real mark.  Failing that, a badge needs a colour
to fill -- and an unknown brand colour is left unknown here for the same
reason `chat-mark-provider-faces' leaves it out, rather than being
guessed at so that every row can have a picture."
  (if-let* ((file (chat-mark--logo-file provider)))
      (create-image file nil nil :height size :ascent 'center :scale 1)
    (when colour
      (create-image (chat-mark-badge-svg glyph colour size)
                    'svg t :ascent 'center :scale 1))))

(defun chat-mark--line-height ()
  "Return the height to draw a mark at, or nil when the frame cannot say.

`default-font-height' asks the selected frame for its font and signals
when there is no font to ask about.  That is not only batch: a frame can
be graphical and still be part-built when a redraw runs on it.  This is
reached from the prompt, which is rebuilt on every send, so a signal here
would take out the whole prompt rather than one badge -- and there is
nothing to recover, because no height means no image and no image means
the glyph."
  (when-let* ((height (ignore-errors (default-font-height))))
    (max 8 (round (* chat-mark-logo-scale height)))))

(defun chat-mark-provider-image (provider glyph face)
  "Return an image for PROVIDER's mark, or nil to leave GLYPH as it is.

GLYPH goes inside a generated badge; FACE supplies the colour it is
filled with, resolved now so that a theme change is picked up on the next
redraw.

Returns nil, never a placeholder, in every case it cannot serve: images
switched off, no graphical frame, no librsvg, a glyph that is already a
recognisable mark with no logo file to better it, a provider with no
brand colour, or a frame that cannot be measured.  The caller puts what
comes back over the glyph, so nil is not a failure to handle -- it is the
glyph, which is what was drawn before any of this existed."
  (when (and chat-mark-logo-enabled provider (display-graphic-p))
    (let ((file (chat-mark--logo-file provider))
          (colour (and face (face-foreground face nil 'default))))
      ;; Establish that there is something to draw before measuring the
      ;; frame to draw it at.  Most calls arrive with nothing to draw, and
      ;; the measurement is the one step here that can fail.
      (when (or file
                (and colour
                     (image-type-available-p 'svg)
                     ;; A listed glyph resembles the logo already, and a
                     ;; letter in a box is not an improvement on it.  The
                     ;; badge exists to replace an initial, which
                     ;; resembles nothing.
                     (not (assq provider chat-mark-provider-marks))))
        (when-let* ((size (chat-mark--line-height)))
          (let* ((key (list provider glyph colour size))
                 (cached (gethash key chat-mark--image-cache 'missing)))
            (if (not (eq cached 'missing))
                cached
              (when (> (hash-table-count chat-mark--image-cache)
                       chat-mark--image-cache-limit)
                (clrhash chat-mark--image-cache))
              (puthash key
                       (ignore-errors
                         (chat-mark--build-image provider glyph colour size))
                       chat-mark--image-cache))))))))

(provide 'chat-mark)
;;; chat-mark.el ends here
