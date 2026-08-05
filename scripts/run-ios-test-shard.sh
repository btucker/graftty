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
read -r -a TEST_ARGUMENTS_ARRAY <<< "$TEST_ARGUMENTS"

cleanup_simulator() {
  xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
}
trap cleanup_simulator EXIT

simulator_exists() {
  xcrun simctl list devices | grep -Fq "($SIMULATOR_UDID)"
}

create_and_boot_simulator() {
  SIMULATOR_UDID="$(
    xcrun simctl create "Graftty CI ($SHARD_NAME) retry" "$SIMULATOR_DEVICE_TYPE"
  )"
  export SIMULATOR_UDID
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "SIMULATOR_UDID=$SIMULATOR_UDID" >> "$GITHUB_ENV"
  fi
  xcrun simctl boot "$SIMULATOR_UDID"
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b
}

run_test_shard() {
  xcodebuild \
    -xctestrun "${XCTESTRUN_PATHS[0]}" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -destination-timeout 15 \
    "${TEST_ARGUMENTS_ARRAY[@]}" \
    test-without-building
}

# xcodebuild occasionally loses a freshly booted simulator when CoreSimulator
# restarts after first-boot data migration. Preserve every ordinary build/test
# failure, but recover once when exit 70 coincides with the selected UDID
# actually disappearing from the device set.
set +e
run_test_shard
TEST_STATUS=$?
set -e

if [[ "$TEST_STATUS" -eq 0 ]]; then
  exit 0
fi
if [[ "$TEST_STATUS" -ne 70 ]] || simulator_exists; then
  exit "$TEST_STATUS"
fi

echo "::warning::iOS simulator $SIMULATOR_UDID disappeared; recreating it and retrying shard once"
create_and_boot_simulator
run_test_shard
