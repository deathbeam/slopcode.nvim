#!/bin/sh
# Ensure every .lua file has a GPL-2.0-only SPDX header with a blank line after it.
# Usage: scripts/license-fix.sh [lint|format]

set -e

mode="${1:-lint}"
files=$(find . -name '*.lua' -not -path './.deps/*')
issues=0

for f in $files; do
	if ! head -1 "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-only'; then
		echo "missing license header: $f"
		issues=$((issues + 1))
		if [ "$mode" = "format" ]; then
			sed -i '1i\-- SPDX-License-Identifier: GPL-2.0-only\n' "$f"
			echo "  -> added license header"
		fi
	elif [ "$(sed -n '2p' "$f")" != '' ]; then
		echo "missing blank line after header: $f"
		issues=$((issues + 1))
		if [ "$mode" = "format" ]; then
			sed -i '1a\\' "$f"
			echo "  -> added blank line"
		fi
	fi
done

if [ "$issues" -gt 0 ]; then
	echo "$issues file(s) with license issues"
	if [ "$mode" = "lint" ]; then
		exit 1
	fi
else
	echo "all files have valid license headers"
fi