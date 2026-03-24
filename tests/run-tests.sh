#!/bin/bash
# Run all chat.el tests

cd "$(dirname "$0")/.."

emacs -Q -batch \
  -l chat-session.el \
  -l chat-files.el \
  -l chat.el \
  -l tests/unit/test-helper.el \
  -l tests/unit/test-chat-session.el \
  -l tests/unit/test-chat-files.el \
  -l tests/unit/test-chat.el \
  -f ert-run-tests-batch-and-exit
