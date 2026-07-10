#!/usr/bin/env bash
set -euo pipefail

chunk_size="${SWIFT_TEST_CI_CHUNK_SIZE:-12}"
if ! [[ "$chunk_size" =~ ^[1-9][0-9]*$ ]]; then
  echo "SWIFT_TEST_CI_CHUNK_SIZE must be a positive integer, got: $chunk_size" >&2
  exit 2
fi

test_list="$(mktemp)"
trap 'rm -f "$test_list"' EXIT

swift test list --skip-build > "$test_list"

suites=()
while IFS= read -r suite; do
  suites+=("$suite")
done < <(awk -F/ '/^[[:alnum:]_]+Tests\./ && $1 != "OwnershipModelTests" { print $1 }' "$test_list" | sort -u)

if [[ "${#suites[@]}" -eq 0 ]]; then
  echo "No Swift test suites found." >&2
  exit 1
fi

total="${#suites[@]}"
chunks=$(( (total + chunk_size - 1) / chunk_size ))

echo "Running $total Swift test suites in $chunks chunks of up to $chunk_size suites."

chunk=1
for (( start = 0; start < total; start += chunk_size )); do
  end=$(( start + chunk_size ))
  if (( end > total )); then
    end="$total"
  fi

  regex=""
  for (( i = start; i < end; i++ )); do
    escaped="${suites[$i]//./\\.}"
    if [[ -z "$regex" ]]; then
      regex="$escaped"
    else
      regex="$regex|$escaped"
    fi
  done

  echo "::group::Swift test chunk $chunk/$chunks suites $(( start + 1 ))-$end"
  swift test \
    --skip-build \
    --experimental-maximum-parallelization-width 1 \
    --filter "^($regex)(/|$)"
  echo "::endgroup::"

  chunk=$(( chunk + 1 ))
done
