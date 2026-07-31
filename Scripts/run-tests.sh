#!/usr/bin/env bash
#
# run-tests.sh — run the full suite on a machine with Command Line Tools but no Xcode.
#
# WHY THIS EXISTS: a plain `swift test` fails here with `no such module 'Testing'`, which looks
# like "swift-testing is not installed". It is installed — the CLT ships
# `Testing.framework` under Library/Developer/Frameworks — but three things are missing that
# Xcode would otherwise provide:
#
#   1. that directory is not on the framework search path      → -F
#   2. the `_Testing_Foundation` cross-import overlay is EMPTY
#      (`_Testing_Foundation.framework/Modules` has no module) → -disable-cross-import-overlays
#   3. the built .xctest bundle has no rpath to the framework,
#      so it links but dies in dlopen at launch                → -rpath
#
# With those three, the suite compiles, links and runs normally.
#
# Usage:  Scripts/run-tests.sh [extra swift-test args…]
#   e.g.  Scripts/run-tests.sh --filter ClaudeIdentityResolverTests
#
# NOTE: `--no-parallel` is deliberate. `CredentialLoadOrderTests` races with
# `RefreshOwnershipTests` over the real system keychain when run in parallel.

set -euo pipefail

cd "$(dirname "$0")/.."

FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"

if [[ ! -d "${FRAMEWORKS}/Testing.framework" ]]; then
    echo "error: Testing.framework not found at ${FRAMEWORKS}" >&2
    echo "       With a full Xcode installed, plain \`swift test\` should work — try that." >&2
    exit 1
fi

exec swift test \
    --arch arm64 \
    --no-parallel \
    -Xswiftc -F -Xswiftc "${FRAMEWORKS}" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "${FRAMEWORKS}" \
    -Xlinker -rpath -Xlinker "${FRAMEWORKS}" \
    "$@"
