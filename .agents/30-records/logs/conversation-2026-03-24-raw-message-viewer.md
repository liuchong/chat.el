# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

# Raw Message Viewer Feature

**Date**: 2026-03-24  
**Status**: ✅ COMPLETE

## Requirements

Add functionality to save and view raw API request/response JSON for each conversation turn, similar to OpenCode's raw message viewer.

## Technical Design

### Data Structure Changes

Extended `chat-message` struct to store raw JSON:

```elisp
(cl-defstruct chat-message
  ;; ... existing fields ...
  raw-request           ; Raw API request JSON (for user messages)
  raw-response)         ; Raw API response JSON (for assistant messages)
```

### API Return Format Change

Modified `chat-llm-request` to return a plist instead of just content string:

```elisp
;; Before
(defun chat-llm-request (...)
  "Returns the response content string."
  ...
  content)

;; After  
(defun chat-llm-request (...)
  "Returns a plist with :content, :raw-request and :raw-response."
  ...
  (list :content parsed-content
        :raw-request raw-request-json
        :raw-response raw-response-json))
```

### User Interface Commands

Added two interactive commands:

1. `chat-view-raw-message` - View raw API exchange for the last assistant message
2. `chat-view-last-raw-exchange` - Alias for the above

Display format shows both request and response JSON in a formatted, read-only buffer.

## Implementation Details

### Data Flow

1. User sends message → `chat-llm-request` builds and sends request
2. Raw request JSON captured before sending
3. Raw response JSON captured after receiving
4. Both stored in the assistant message's `raw-request` and `raw-response` fields
5. User can view anytime via `M-x chat-view-last-raw-exchange`

### JSON Formatting

Raw JSON is automatically pretty-printed using `json-pretty-print-buffer` for readability.

## Files Modified

| File | Changes |
|------|---------|
| `chat-session.el` | Added `raw-request` and `raw-response` fields to `chat-message` struct |
| `chat-llm.el` | Modified `chat-llm-request` to return plist with raw data |
| `chat-ui.el` | Extract raw data from response, save to message, add viewer commands |

## Testing

- All 64 unit tests passing
- Raw message storage verified in session messages
- JSON formatting works correctly
- Commands accessible via M-x

## Usage

```elisp
;; After sending a message and receiving response
M-x chat-view-last-raw-exchange

;; Displays formatted JSON:
;; ========================================
;; Message ID: msg-xxx
;; ========================================
;; 
;; --- REQUEST ---
;; { "model": "kimi-for-coding", "messages": [...], ... }
;; 
;; --- RESPONSE ---
;; { "choices": [...], ... }
```

## Notes

- Raw data is stored per-message, enabling historical inspection
- View buffer is read-only (`view-mode`)
- Only assistant messages have both request and response data
- User messages don't have raw data since they're not API calls
