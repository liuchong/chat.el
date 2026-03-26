#!/bin/bash
# Run all chat.el tests through the shared batch entrypoint.
cd "$(dirname "$0")/.."
exec emacs -Q -batch -l tests/run-tests.el
