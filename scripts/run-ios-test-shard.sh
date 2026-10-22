#!/usr/bin/env bash
set -euo pipefail

: "${SHARD_NAME:?SHARD_NAME is required}"
: "${SIMULATOR_UDID:?SIMULATOR_UDID is required}"
: "${TEST_ARGUMENTS:?TEST_ARGUMENTS is required}"

SIMULATOR_DEVICE_TYPE="${SIMULATOR_DEVICE_TYPE:-iPhone 17}"

XCTESTRUN_PATHS=(.derivedData/Build/Products/*.xctestrun)
if [[ ! -e "${XCTESTRUN_PATHS[0]}" ]]; then
  echo "::error::build-for-testing did not produce an .xctestrun file"
  exit 1
fi
FIRST_ATTEMPT_LOG=""
RESULTS_DIRECTORY="${RESULTS_DIRECTORY:-.ci-results/ios}"
mkdir -p "$RESULTS_DIRECTORY"
SIMULATOR_UDIDS=("$SIMULATOR_UDID")

delete_simulator() {
  local udid="$1"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}

cleanup() {
  local udid
  for udid in "${SIMULATOR_UDIDS[@]}"; do
    delete_simulator "$udid"
  done
  if [[ -n "$FIRST_ATTEMPT_LOG" ]]; then
    rm -f "$FIRST_ATTEMPT_LOG"
  fi
}
trap cleanup EXIT
FIRST_ATTEMPT_LOG="$(mktemp "${TMPDIR:-/tmp}/graftty-ios-test-shard.XXXXXX")"

simulator_is_available() {
  xcrun simctl list devices available | grep -F "($SIMULATOR_UDID)" >/dev/null
}

destination_resolution_failed() {
  grep -Fq \
    "Unable to find a device matching the provided destination specifier:" \
    "$FIRST_ATTEMPT_LOG"
}

create_and_boot_simulator() {
  SIMULATOR_UDID="$(
    xcrun simctl create "Graftty CI ($SHARD_NAME) retry" "$SIMULATOR_DEVICE_TYPE"
  )" || return $?
  SIMULATOR_UDIDS+=("$SIMULATOR_UDID")
  export SIMULATOR_UDID
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "SIMULATOR_UDID=$SIMULATOR_UDID" >> "$GITHUB_ENV" || return $?
  fi
  xcrun simctl boot "$SIMULATOR_UDID" || return $?
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b
}

run_test_shard() {
  xcodebuild \
    -xctestrun "${XCTESTRUN_PATHS[0]}" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -destination-timeout 60 \
    -resultBundlePath "$RESULTS_DIRECTORY/batch-$TEST_BATCH-attempt-$1.xcresult" \
    "${TEST_ARGUMENTS_ARRAY[@]}" \
    test-without-building
}

run_with_recovery() {
  # xcodebuild occasionally loses a freshly booted simulator when CoreSimulator
  # restarts after first-boot data migration. Preserve every ordinary build/test
  # failure, but recover once when exit 70 coincides with either the selected UDID
  # disappearing from the available device set or Xcode rejecting its destination.
  run_test_shard 1 2>&1 | tee "$FIRST_ATTEMPT_LOG"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
  TEST_STATUS="${PIPELINE_STATUSES[0]}"
  if [[ "${PIPELINE_STATUSES[1]}" -ne 0 ]]; then
    return "${PIPELINE_STATUSES[1]}"
  fi

  if [[ "$TEST_STATUS" -eq 0 ]]; then
    return 0
  fi
  if [[ "$TEST_STATUS" -ne 70 ]]; then
    return "$TEST_STATUS"
  fi
  if simulator_is_available && ! destination_resolution_failed; then
    return "$TEST_STATUS"
  fi

  echo "::warning::iOS simulator $SIMULATOR_UDID became unavailable to xcodebuild; recreating it and retrying shard once"
  delete_simulator "$SIMULATOR_UDID"
  create_and_boot_simulator || return $?
  run_test_shard 2
}

# Preserve separate integration test processes while reusing the booted device.
# Run every batch even if one fails, retaining the first failure status.
TEST_BATCH=0
OVERALL_STATUS=0
while IFS= read -r arguments; do
  [[ -n "$arguments" ]] || continue
  TEST_BATCH=$((TEST_BATCH + 1))
  read -r -a TEST_ARGUMENTS_ARRAY <<< "$arguments"
  echo "::group::$SHARD_NAME batch $TEST_BATCH"
  if run_with_recovery; then
    :
  else
    status=$?
    if [[ "$OVERALL_STATUS" -eq 0 ]]; then OVERALL_STATUS=$status; fi
  fi
  echo "::endgroup::"
done <<< "$TEST_ARGUMENTS"
[[ "$TEST_BATCH" -gt 0 ]] || { echo "::error::No iOS test batches selected"; exit 1; }
exit "$OVERALL_STATUS"
