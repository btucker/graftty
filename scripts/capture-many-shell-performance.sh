#!/bin/bash

# Capture one Graftty process across at least one 30-second poll alignment.
# While this runs, type continuously in a busy terminal pane so the sample
# covers the user-visible symptom as well as the background process fan-out.

set -uo pipefail

duration="${GRAFTTY_CAPTURE_SECONDS:-35}"
pid="${1:-}"

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
    echo "GRAFTTY_CAPTURE_SECONDS must be a positive integer." >&2
    exit 1
fi

if [[ -z "$pid" ]]; then
    pid="$(pgrep -x Graftty | head -n 1 || true)"
fi

if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
    echo "Could not find a running Graftty process." >&2
    echo "Usage: $0 [pid]" >&2
    echo "Available matches:" >&2
    pgrep -fl Graftty >&2 || true
    exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if ! output_dir="$(mktemp -d "/private/tmp/Graftty-performance-$timestamp-XXXXXX")"; then
    echo "Could not create the capture directory." >&2
    exit 1
fi

metadata_status=0
{
    echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "duration_seconds=$duration"
    echo "pid=$pid"
    echo "process_sampling_interval_seconds=0.1"
    echo "process_sampling_scope=descendant git/gh/glab processes (sampled lower bound)"
    sw_vers
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
    sysctl -n hw.memsize 2>/dev/null || true
    ps -p "$pid" -o pid=,ppid=,%cpu=,%mem=,rss=,vsz=,etime=,state=,command=
} > "$output_dir/metadata.txt" || metadata_status=$?

sample "$pid" "$duration" 10 \
    -file "$output_dir/Graftty.sample.txt" \
    > "$output_dir/sample-command.txt" 2>&1 &
sample_job=$!

top -l "$duration" -s 1 -pid "$pid" \
    -stats pid,command,cpu,threads,mem,state,time \
    > "$output_dir/Graftty.top.txt" 2>&1 &
top_job=$!

iterations=$((duration * 10))
children_status=0
{
    for ((iteration = 0; iteration < iterations; iteration += 1)); do
        if ! ps -axo ppid=,pid=,%cpu=,comm= | awk -v parent="$pid" -v tick="$iteration" '
        function basename(path, pieces, count) {
            count = split(path, pieces, "/")
            return pieces[count]
        }
        {
            parents[$2] = $1
            cpu[$2] = $3
            names[$2] = basename($4)
        }
        END {
            for (child in names) {
                ancestor = parents[child]
                hops = 0
                while (ancestor != "" && ancestor != 0 && ancestor != parent && hops < 100) {
                    ancestor = parents[ancestor]
                    hops += 1
                }
                name = names[child]
                if (ancestor == parent && (name == "git" || name == "gh" || name == "glab")) {
                    count += 1
                    child_cpu += cpu[child]
                    children = children sprintf(" %s:%s", child, name)
                }
            }
            printf "%d %d %.1f%s\n", tick, count + 0, child_cpu + 0, children
        }
    '; then
            children_status=1
            break
        fi
        sleep 0.1
    done
} > "$output_dir/background-children.txt"

sample_status=0
top_status=0
wait "$sample_job" || sample_status=$?
wait "$top_job" || top_status=$?

children_summary_status=0
awk '
    NR == 1 || $2 > maximum { maximum = $2; line = $0 }
    NR == 1 || $3 > maximum_cpu { maximum_cpu = $3; cpu_line = $0 }
    END {
        print "maximum_background_children=" maximum + 0
        print "maximum_sample=" line
        print "maximum_background_child_cpu=" maximum_cpu + 0
        print "maximum_cpu_sample=" cpu_line
    }
' "$output_dir/background-children.txt" > "$output_dir/summary.txt" \
    || children_summary_status=$?

top_summary_status=0
awk -v target="$pid" '
    $1 == target {
        samples += 1
        total_cpu += $3
        if (samples == 1 || $3 > maximum_cpu) maximum_cpu = $3
    }
    END {
        printf "graftty_cpu_samples=%d\n", samples
        printf "graftty_average_cpu=%.1f\n", samples ? total_cpu / samples : 0
        printf "graftty_maximum_cpu=%.1f\n", maximum_cpu + 0
    }
' "$output_dir/Graftty.top.txt" >> "$output_dir/summary.txt" \
    || top_summary_status=$?

{
    echo "sample_exit_status=$sample_status"
    echo "top_exit_status=$top_status"
    echo "metadata_exit_status=$metadata_status"
    echo "children_exit_status=$children_status"
    echo "children_summary_exit_status=$children_summary_status"
    echo "top_summary_exit_status=$top_summary_status"
} >> "$output_dir/summary.txt"

archive="$output_dir.zip"
archive_status=0
ditto -c -k --sequesterRsrc --keepParent "$output_dir" "$archive" \
    || archive_status=$?
echo "archive_exit_status=$archive_status" >> "$output_dir/summary.txt"

cat "$output_dir/summary.txt"
if [[ "$archive_status" -eq 0 ]]; then
    echo "Capture archive: $archive"
else
    echo "Capture directory: $output_dir"
fi

if [[ "$sample_status" -ne 0 ]]; then
    echo "sample failed; inspect $output_dir/sample-command.txt" >&2
    exit "$sample_status"
elif [[ "$top_status" -ne 0 ]]; then
    echo "top failed; inspect $output_dir/Graftty.top.txt" >&2
    exit "$top_status"
elif [[ "$metadata_status" -ne 0 || "$children_status" -ne 0 \
        || "$children_summary_status" -ne 0 || "$top_summary_status" -ne 0 ]]; then
    echo "one or more capture collectors failed; inspect $output_dir" >&2
    exit 1
elif [[ "$archive_status" -ne 0 ]]; then
    echo "archive creation failed; capture directory remains at $output_dir" >&2
    exit "$archive_status"
fi
