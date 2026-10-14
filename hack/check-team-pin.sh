#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# check-team-pin.sh <executable> <team-id>
#
# Checks the Team ID pin compiled into the app executable (TeamIDPin): the
# binary must hold exactly one stamp "k3sm-team-id-pin:<suffix>" with a
# non-empty suffix, and that suffix must equal <team-id> exactly. The bare
# marker "k3sm-team-id-pin:" (the TeamIDPin.marker constant) may appear once
# on its own and is not a stamp. A longer suffix, a second stamp, a second
# bare marker or no stamp at all fails. Used by hack/build-app.sh --team-id
# and hack/release/sign-and-notarize.sh; reads the file and changes nothing.
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "usage: hack/check-team-pin.sh <executable> <team-id>" >&2
	exit 2
fi
bin="$1"
team="$2"
printf '%s\n' "$team" | /usr/bin/grep -Eqx '[A-Z0-9]{10}' \
	|| { echo "check-team-pin: not a Team ID: $team" >&2; exit 2; }
[ -f "$bin" ] || { echo "check-team-pin: no such file: $bin" >&2; exit 2; }

marker='k3sm-team-id-pin:'
# Every occurrence of the marker with the printable bytes that follow it. A
# compiled Swift string literal ends at a NUL, so a stamp's suffix is exactly
# its Team ID unless something longer was compiled in.
found="$(LC_ALL=C /usr/bin/grep -ao "${marker}[[:print:]]*" "$bin" || true)"
bare=0
stamps=0
value=
while IFS= read -r occurrence; do
	[ -n "$occurrence" ] || continue
	suffix="${occurrence#"$marker"}"
	if [ -z "$suffix" ]; then
		bare=$((bare + 1))
	else
		stamps=$((stamps + 1))
		value="$suffix"
	fi
done <<EOS
$found
EOS

if [ "$bare" -gt 1 ]; then
	echo "check-team-pin: $bin holds the bare marker $bare times, want at most 1" >&2
	exit 1
fi
if [ "$stamps" -ne 1 ]; then
	echo "check-team-pin: $bin holds $stamps Team ID stamps, want exactly 1" >&2
	exit 1
fi
if [ "$value" != "$team" ]; then
	echo "check-team-pin: $bin is pinned to '$value', not $team" >&2
	exit 1
fi
echo "check-team-pin: $bin is pinned to $team"
