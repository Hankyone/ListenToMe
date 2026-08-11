#!/bin/zsh

# Run the same checks GitHub Actions expects before pushing to main / tagging.
# Prefer failing here over a red Actions email.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

MIN_MAJOR="${LISTEN_TO_ME_MIN_SWIFT_MAJOR:-6}"
MIN_MINOR="${LISTEN_TO_ME_MIN_SWIFT_MINOR:-2}"

print "→ Selecting CI-compatible Xcode"
export DEVELOPER_DIR="$("$SCRIPT_DIR/select-ci-xcode.sh" --print)"
"$SCRIPT_DIR/select-ci-xcode.sh" >/dev/null

print "→ Resolving packages"
xcrun swift package resolve

print "→ Checking dependency Swift tools versions"
python3 "$SCRIPT_DIR/check-dependency-swift-tools.py" "$MIN_MAJOR" "$MIN_MINOR"

print "→ Tests"
"$SCRIPT_DIR/test.sh"

print "→ Ad-hoc package"
"$SCRIPT_DIR/package-app.sh"

print "CI preflight passed. Safe to push."
