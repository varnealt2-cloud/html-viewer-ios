#!/bin/bash
# usage: run_tests.sh <simulator-udid> <tag>
# Runs the unit and UI tests on one simulator (a failing test is retried up to twice: shared CI simulators stall); logs to build/tests-<tag>.log, screenshots to build/snapshots.
set -o pipefail
UDID="$1"; TAG="$2"
LOG="build/tests-$TAG.log"
xcrun simctl list devices available | grep "$UDID" | tee "$LOG"
export TEST_RUNNER_SNAPSHOT_DIR="$PWD/build/snapshots"
export TEST_RUNNER_SNAPSHOT_TAG="$TAG"
xcodebuild test -project HTMLViewer.xcodeproj -scheme HTMLViewer \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/DerivedDataSim -resultBundlePath "build/Tests-$TAG.xcresult" \
  -retry-tests-on-failure -test-iterations 3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee -a "$LOG" | grep -E "error:|Test Case|Executed|\*\* |XCTAssert" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"
