#!/bin/zsh
# Refuses GPL-family license text in the absorbed Ghostty Swift sources and
# their resources.
#
# GhosttyTerminal ships its resource bundle in the iOS app. Ghostty's bash
# and zsh shell integration (derived from Kitty) is GPLv3; the integration
# under Resources/Ghostty/shell-integration is libghostty-spm's MIT rewrite.
# This check keeps the upstream files from coming back.
set -euo pipefail
cd "$(dirname "$0")/../../.."

# Kept to license *text* and SPDX identifiers so prose about the policy does
# not trip it. The bracketed letters keep the names themselves out of here.
patterns=(
    'GNU (Lesser |Affero )?General Public Licen[s]e'
    'SPDX-License-Identifier: *[AL]?GPL'
    'distributed under (the )?(GNU )?[AL]?GPL'
    'licensed under (the )?(GNU )?[AL]?GPL'
    'under the terms of the GN[U]'
    'www\.gnu\.org/licenses/(a|l)?gpl'
)
scope=(Sources/GhosttyKit Sources/GhosttyTerminal deps/ghostty)

failed=0
for pattern in "${patterns[@]}"; do
    hits="$(git grep -I -n -i -E -- "$pattern" -- "${scope[@]}" ':(exclude)deps/ghostty/tests/check-licenses.sh' || true)"
    if [[ -n "$hits" ]]; then
        echo "[-] GPL license text matched /$pattern/:"
        print -r -- "$hits" | sed 's/^/    /'
        failed=1
    fi
done

expected_integration=(
    bash/LICENSE-bash-preexec.md
    bash/bash-preexec.sh
    bash/ghostty.bash
    zsh/.zshenv
    zsh/ghostty-integration
)
integration_dir=Sources/GhosttyTerminal/Resources/Ghostty/shell-integration
if ! diff_output="$(diff \
    <(print -l -- "${expected_integration[@]}" | LC_ALL=C sort) \
    <(git ls-files "$integration_dir" | sed "s|^$integration_dir/||" | LC_ALL=C sort))"; then
    echo "[-] $integration_dir holds files other than the MIT set (< expected, > found):"
    print -r -- "$diff_output" | sed 's/^/    /'
    failed=1
fi

if (( failed == 0 )); then
    echo "[+] no GPL license text; shell-integration holds only the MIT files"
fi
exit $failed
