#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# measure-polls.sh -- what the running app costs while it polls k3sm, over a
# window, in one state (for example "workloads-open" or "window-closed").
#
#   measure-polls.sh --state <label> --out <dir> [--window <seconds>]
#                    [--pid <app pid>] [--cli <k3sm path>]
#   measure-polls.sh --aggregate <log>
#   measure-polls.sh --self-test
#
# An attended run on a Mac with the app open in the state named by --state.
# It records, for the app's process:
#   - the k3sm processes the app and its descendants started in the window,
#     from `sudo eslogger exec` (Endpoint Security; the terminal running this
#     needs Full Disk Access), keeping only each exec's time, pid, parent pid
#     and executable path (a JSON string, so no path can forge a record),
#     never its arguments, and only for an exec whose path ends in /k3sm or
#     /kubectl or whose parent chain leads to the app;
#   - the app's own and its reaped children's CPU time (proc_pid_rusage:
#     ri_user_time, ri_system_time, ri_child_user_time, ri_child_system_time,
#     end minus start) and its physical footprint at the end and lifetime
#     maximum (ri_phys_footprint, ri_lifetime_max_phys_footprint), read by a
#     small helper compiled with cc into a private temporary directory that
#     is removed at exit;
#   - the cluster's pod and node counts, read once before the window.
# The log goes to <out>/<label>.log and the one-line summary, also printed,
# to <out>/<label>.summary. There is no default output directory; it is
# created mode 0700, and an existing one must be yours and writable by no
# one else. The raw log names local executables and process ids: keep it
# private. Only the summary is meant to be shared.
#
# eslogger runs as root; its pid is kept in a private temporary directory,
# and it is stopped only after that pid is checked to be /usr/bin/eslogger.
#
# The summary is a pure function of the log (--aggregate), so a log can be
# re-read later. A k3sm process counts once per pid when its parent is the
# app or one of the app's descendants seen by eslogger; a child the app
# started before eslogger attached is not seen, nor are its children.
#
# --self-test runs the aggregation, the capture filter, the eslogger line
# conversion and the output directory check against canned input: a good
# log's summary, and a refusal for each malformed one.
set -euo pipefail

LOG_VERSION=2

usage() {
	sed -n '8,11p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

die() {
	echo "measure-polls: $*" >&2
	exit 1
}

# aggregate <log>: print the one-line summary of a measurement log, or refuse
# a log that is malformed. The log, one record per line:
#   measure-polls <version>
#   state <label>
#   window <seconds>
#   pid <app pid>
#   pods <n|unknown>
#   nodes <n|unknown>
#   start <epoch> <pid> <user ns> <system ns> <child user ns> <child system ns> <footprint> <lifetime max>
#   end   <same fields as start>
#   spawn <epoch> <pid> <ppid> <executable path as a JSON string>   (any number, in eslogger order)
aggregate() {
	local log="$1"
	[ -f "$log" ] || die "no log at $log"
	awk -v want_version="$LOG_VERSION" '
	function refuse(why) { print "measure-polls: refused: line " NR ": " why > "/dev/stderr"; bad = 1; exit 1 }
	function whole(s) { return s ~ /^[0-9]+$/ }
	function once(key) { if (key in seen) refuse("a second " key " line"); seen[key] = 1 }
	function rusage(kind,   i) {
		once(kind)
		if (NF != 9) refuse(kind " wants 8 fields, has " NF - 1)
		for (i = 2; i <= 9; i++) if (!whole($i)) refuse(kind " field " i - 1 " is not a whole number: " $i)
		for (i = 2; i <= 9; i++) r[kind, i] = $i + 0
	}
	{
		if (NR == 1) {
			if ($1 != "measure-polls" || NF != 2) refuse("not a measure-polls log")
			if ($2 != want_version) refuse("log version " $2 ", want " want_version)
			next
		}
		if ($0 ~ /^[[:space:]]*$/) next
		kind = $1
		if (kind == "state") {
			once(kind); if (NF != 2 || $2 !~ /^[A-Za-z0-9._-]+$/) refuse("state wants one label of letters, digits, dot, dash or underscore"); state = $2
		} else if (kind == "window") {
			once(kind); if (NF != 2 || !whole($2) || $2 + 0 == 0) refuse("window wants a positive whole number of seconds"); window = $2 + 0
		} else if (kind == "pid") {
			once(kind); if (NF != 2 || !whole($2) || $2 + 0 == 0) refuse("pid wants a positive whole number"); app = $2 + 0
		} else if (kind == "pods" || kind == "nodes") {
			once(kind); if (NF != 2 || (!whole($2) && $2 != "unknown")) refuse(kind " wants a whole number or unknown"); count[kind] = $2
		} else if (kind == "start" || kind == "end") {
			rusage(kind)
		} else if (kind == "spawn") {
			if (NF < 5) refuse("spawn wants a time, a pid, a parent pid and a path")
			if (!whole($2) || !whole($3) || !whole($4)) refuse("spawn time, pid and parent pid must be whole numbers")
			n_spawn++
			s_time[n_spawn] = $2 + 0; s_pid[n_spawn] = $3 + 0; s_ppid[n_spawn] = $4 + 0
			path = $0; sub(/^spawn[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", path)
			if (path !~ /^".*"$/) refuse("spawn path must be a JSON string")
			s_path[n_spawn] = path
		} else {
			refuse("unknown record " kind)
		}
	}
	END {
		if (bad) exit 1
		if (NR == 0) { print "measure-polls: refused: empty log" > "/dev/stderr"; exit 1 }
		split("state window pid pods nodes start end", need, " ")
		for (i = 1; i <= 7; i++) if (!(need[i] in seen)) { print "measure-polls: refused: no " need[i] " line" > "/dev/stderr"; exit 1 }
		if (r["start", 3] != app || r["end", 3] != app) { print "measure-polls: refused: the rusage pid is not the app pid " app > "/dev/stderr"; exit 1 }
		elapsed = r["end", 2] - r["start", 2]
		if (elapsed <= 0) { print "measure-polls: refused: the end is not after the start" > "/dev/stderr"; exit 1 }
		cpu = 0
		for (i = 4; i <= 7; i++) {
			d = r["end", i] - r["start", i]
			if (d < 0) { print "measure-polls: refused: a CPU counter went back; was the app restarted?" > "/dev/stderr"; exit 1 }
			cpu += d
		}
		if (r["end", 9] < r["end", 8]) { print "measure-polls: refused: the lifetime maximum is below the footprint" > "/dev/stderr"; exit 1 }
		# The app and every process it started, in eslogger order; a k3sm
		# executable counts once per pid, inside the window only.
		tree[app] = 1
		spawns = 0; descendants = 0
		for (i = 1; i <= n_spawn; i++) {
			if (!(s_ppid[i] in tree) && !(s_pid[i] in tree)) continue
			if (!(s_pid[i] in tree)) { tree[s_pid[i]] = 1; fresh = 1 } else fresh = 0
			inside = s_time[i] >= r["start", 2] && s_time[i] <= r["end", 2]
			if (inside && fresh) descendants++
			if (inside && s_path[i] ~ /\/k3sm"$/ && !(s_pid[i] in counted)) { counted[s_pid[i]] = 1; spawns++ }
		}
		mib = 1048576
		printf "state=%s window_s=%d elapsed_s=%d k3sm_spawns=%d k3sm_spawns_per_min=%.1f descendants=%d cpu_s=%.3f cpu_s_per_min=%.3f footprint_mib=%.1f lifetime_max_mib=%.1f pods=%s nodes=%s\n", \
			state, window, elapsed, spawns, spawns * 60 / elapsed, descendants, cpu / 1e9, cpu / 1e9 * 60 / elapsed, \
			r["end", 8] / mib, r["end", 9] / mib, count["pods"], count["nodes"]
	}' "$log"
}

# es_lines: read eslogger's JSON exec events on stdin and print one spawn
# record per event: time (whole seconds), pid, parent pid, and the executable
# path as a JSON string, so a newline in a path stays inside its record.
# Arguments are never read, so no command line reaches the log.
es_lines() {
	/usr/bin/jq -r --unbuffered '
		.event.exec.target as $t
		| "spawn \(.time | sub("\\.[0-9]+"; "") | fromdateiso8601) \($t.audit_token.pid) \($t.ppid) \($t.executable.path | @json)"'
}

# capture_filter <app pid>: keep a spawn record only when its parent chain
# leads to the app (as seen so far) or its path ends in /k3sm or /kubectl;
# every other exec on the Mac is dropped before anything is written.
capture_filter() {
	awk -v app="$1" '
	BEGIN { tree[app] = 1 }
	{
		keep = 0
		if ($4 in tree) { tree[$3] = 1; keep = 1 }
		else if ($3 in tree) keep = 1
		if ($0 ~ /\/(k3sm|kubectl)"$/) keep = 1
		if (keep) { print; fflush() }
	}'
}

# check_out <dir>: create <dir> mode 0700, or accept an existing one only
# when it is a directory owned by this user and writable by no one else.
check_out() {
	local dir="$1" owner mode
	if [ -e "$dir" ] || [ -L "$dir" ]; then
		[ -d "$dir" ] && [ ! -L "$dir" ] || die "$dir is not a directory"
		read -r owner mode < <(stat -f '%u %Lp' "$dir")
		[ "$owner" = "$(id -u)" ] || die "$dir is owned by someone else"
		(( (8#$mode & 8#022) == 0 )) || die "$dir is writable by group or others"
	else
		mkdir -p "$dir"
		chmod 700 "$dir"
	fi
}

# rusage_helper <dir>: compile the proc_pid_rusage reader into <dir> (the
# private temporary directory) and print
# its path. It prints: epoch pid user_ns system_ns child_user_ns
# child_system_ns footprint lifetime_max (times converted from Mach ticks).
rusage_helper() {
	local dir="$1"
	cat > "$dir/rusage.c" <<'EOF'
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

int main(int argc, char **argv) {
	if (argc != 2) { fprintf(stderr, "usage: rusage <pid>\n"); return 2; }
	int pid = atoi(argv[1]);
	struct rusage_info_v4 ri;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) { perror("proc_pid_rusage"); return 1; }
	mach_timebase_info_data_t tb;
	if (mach_timebase_info(&tb) != KERN_SUCCESS || tb.denom == 0) { fprintf(stderr, "mach_timebase_info failed\n"); return 1; }
#define NS(x) ((unsigned long long)((x) * tb.numer / tb.denom))
	printf("%lld %d %llu %llu %llu %llu %llu %llu\n", (long long)time(NULL), pid,
		NS(ri.ri_user_time), NS(ri.ri_system_time), NS(ri.ri_child_user_time), NS(ri.ri_child_system_time),
		(unsigned long long)ri.ri_phys_footprint, (unsigned long long)ri.ri_lifetime_max_phys_footprint);
	return 0;
}
EOF
	cc -O2 -o "$dir/rusage" "$dir/rusage.c" || die "could not compile the rusage helper (are the Command Line Tools installed?)"
	printf '%s\n' "$dir/rusage"
}

# count_of <cli> <kind>: how many objects of <kind> the cluster has, or unknown.
count_of() {
	local n
	if n="$("$1" kubectl get "$2" -A --no-headers -o name 2>/dev/null | wc -l | tr -d ' ')"; then
		printf '%s\n' "$n"
	else
		echo unknown
	fi
}

# stop_es: end the eslogger run measure started, if one is running. The pid
# is killed only when it is a number and its executable is /usr/bin/eslogger.
WORK=""
ES_PIDFILE=""
ES_READER=""
stop_es() {
	local espid comm
	if [ -n "$ES_PIDFILE" ] && [ -s "$ES_PIDFILE" ]; then
		espid="$(cat "$ES_PIDFILE")"
		if [[ "$espid" =~ ^[0-9]+$ ]]; then
			comm="$(ps -o comm= -p "$espid" 2>/dev/null || true)"
			if [ "$comm" = /usr/bin/eslogger ]; then
				sudo kill "$espid" 2>/dev/null || true
			elif [ -n "$comm" ]; then
				echo "measure-polls: refused to stop pid $espid: it is $comm, not /usr/bin/eslogger" >&2
			fi
		else
			echo "measure-polls: refused to stop eslogger: the pid file holds no pid" >&2
		fi
	fi
	if [ -n "$ES_READER" ]; then
		wait "$ES_READER" 2>/dev/null || true
	fi
	ES_PIDFILE=""
	ES_READER=""
}

# cleanup: stop eslogger and remove the private temporary directory.
cleanup() {
	stop_es
	[ -z "$WORK" ] || rm -rf "$WORK"
	WORK=""
}

measure() {
	local state="" out="" window=300 pid="" cli=/Library/k3sm/k3sm
	while [ $# -gt 0 ]; do
		case "$1" in
		--state) state="${2:-}"; shift 2 ;;
		--out) out="${2:-}"; shift 2 ;;
		--window) window="${2:-}"; shift 2 ;;
		--pid) pid="${2:-}"; shift 2 ;;
		--cli) cli="${2:-}"; shift 2 ;;
		*) usage ;;
		esac
	done
	if [ -z "$state" ] || [ -z "$out" ]; then usage; fi
	[[ "$state" =~ ^[A-Za-z0-9._-]+$ ]] || die "--state takes letters, digits, dot, dash or underscore"
	if ! [[ "$window" =~ ^[0-9]+$ ]] || [ "$window" -eq 0 ]; then
		die "--window takes a positive number of seconds"
	fi
	[ "$(uname -s)" = Darwin ] || die "this measures the macOS app; run it on the Mac"
	[ -x /usr/bin/eslogger ] || die "no /usr/bin/eslogger on this Mac"
	[ -x /usr/bin/jq ] || die "no /usr/bin/jq on this Mac"
	[ -x "$cli" ] || die "no k3sm CLI at $cli (set --cli)"
	if [ -z "$pid" ]; then
		pid="$(pgrep -x k3sm-app || true)"
		[ -n "$pid" ] || die "the app (k3sm-app) is not running; open it in the state to measure"
		[ "$(printf '%s\n' "$pid" | wc -l | tr -d ' ')" = 1 ] || die "more than one k3sm-app is running; pass --pid"
	fi
	if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
		die "no process $pid"
	fi
	umask 077
	check_out "$out"
	out="$(cd "$out" && pwd)"
	local log="$out/$state.log"
	[ ! -e "$log" ] || die "$log exists; pick another --state or --out"

	WORK="$(mktemp -d)"
	chmod 700 "$WORK"
	trap cleanup EXIT
	local exec_log="$WORK/exec" es_err="$WORK/eslogger.err"
	ES_PIDFILE="$WORK/eslogger.pid"

	echo "measure-polls: eslogger needs root; sudo may ask for your password"
	sudo -v
	local helper
	helper="$(rusage_helper "$WORK")"
	"$helper" "$pid" > /dev/null || die "cannot read the app's rusage"

	local pods nodes
	pods="$(count_of "$cli" pods)"
	nodes="$(count_of "$cli" nodes)"

	: > "$exec_log"
	# shellcheck disable=SC2016 # $$ and $1 expand in the root shell, not here.
	sudo /bin/sh -c 'echo $$ > "$1"; exec /usr/bin/eslogger exec' sh "$ES_PIDFILE" 2> "$es_err" \
		| es_lines | capture_filter "$pid" >> "$exec_log" &
	ES_READER=$!
	sleep 3
	[ -s "$ES_PIDFILE" ] || die "eslogger did not start: $(cat "$es_err" 2>/dev/null)"

	local start end
	start="$("$helper" "$pid")" || die "cannot read the app's rusage at the start"
	echo "measure-polls: measuring $state for ${window}s (app pid $pid)"
	sleep "$window"
	end="$("$helper" "$pid")" || die "the app exited during the window"
	sleep 2
	stop_es

	{
		echo "measure-polls $LOG_VERSION"
		echo "state $state"
		echo "window $window"
		echo "pid $pid"
		echo "pods $pods"
		echo "nodes $nodes"
		echo "start $start"
		echo "end $end"
		cat "$exec_log"
	} > "$log"
	aggregate "$log" | tee "$out/$state.summary"
	cleanup
	trap - EXIT
}

self_test() {
	local dir n=0
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' RETURN

	# A good log: app 500; its k3sm children 501 (which execs kubectl in
	# place) and 502, whose own k3sm child 503 counts; 504 and 505 are not
	# the app's; 506 ran before the window and 507 after it; 501 counts once;
	# 509's path carries an escaped newline and a forged record, which stays
	# one descendant that is not k3sm.
	good() {
		cat <<'EOF'
measure-polls 2
state workloads-open
window 300
pid 500
pods 12
nodes 2
start 1000 500 2000000000 1000000000 500000000 250000000 104857600 157286400
end 1300 500 5000000000 2000000000 3500000000 1250000000 125829120 167772160
spawn 990 506 500 "/Library/k3sm/k3sm"
spawn 1001 501 500 "/Library/k3sm/k3sm"
spawn 1001 501 500 "/Library/k3sm/bin/kubectl"
spawn 1002 501 500 "/Library/k3sm/k3sm"
spawn 1010 502 500 "/Library/k3sm/k3sm"
spawn 1011 503 502 "/Library/k3sm/k3sm"
spawn 1020 504 1 "/Library/k3sm/k3sm"
spawn 1021 505 77 "/usr/bin/true"
spawn 1100 508 500 "/Applications/With Space/k3sm"
spawn 1200 509 500 "/tmp/x\nspawn 1201 510 500 \"/Library/k3sm/k3sm\"\nx"
spawn 1301 507 500 "/Library/k3sm/k3sm"
EOF
	}
	local want="state=workloads-open window_s=300 elapsed_s=300 k3sm_spawns=4 k3sm_spawns_per_min=0.8 descendants=5 cpu_s=8.000 cpu_s_per_min=1.600 footprint_mib=120.0 lifetime_max_mib=160.0 pods=12 nodes=2"
	good > "$dir/good.log"
	local got
	got="$(aggregate "$dir/good.log")" || die "self-test: the good log was refused"
	[ "$got" = "$want" ] || die "self-test: summary
  got:  $got
  want: $want"
	n=$((n + 1))

	# Each malformed log must be refused (exit 1) with its reason.
	refused() {
		local name="$1" why="$2"
		local err
		if aggregate "$dir/$name.log" > /dev/null 2> "$dir/$name.err"; then
			die "self-test: $name was accepted"
		fi
		err="$(cat "$dir/$name.err")"
		case "$err" in
		*"$why"*) n=$((n + 1)) ;;
		*) die "self-test: $name: refusal \"$err\" does not say \"$why\"" ;;
		esac
	}
	: > "$dir/empty.log"; refused empty "empty log"
	good | sed '1s/.*/something else/' > "$dir/header.log"; refused header "not a measure-polls log"
	good | sed '1s/2$/1/' > "$dir/version.log"; refused version "log version 1"
	good | grep -v '^end ' > "$dir/noend.log"; refused noend "no end line"
	good | grep -v '^pid ' > "$dir/nopid.log"; refused nopid "no pid line"
	{ good; echo "start 1000 500 1 1 1 1 1 1"; } > "$dir/twostarts.log"; refused twostarts "a second start line"
	good | sed 's/^start 1000 500 2000000000/start 1000 500 2e9/' > "$dir/notint.log"; refused notint "is not a whole number"
	good | sed 's/^end 1300 500 5000000000 2000000000 3500000000 1250000000 125829120 167772160$/end 1300 500 5000000000/' > "$dir/short.log"
	refused short "end wants 8 fields"
	good | sed 's/^end 1300/end 1000/' > "$dir/noelapsed.log"; refused noelapsed "the end is not after the start"
	good | sed 's/^end 1300 500 5000000000/end 1300 500 1000000000/' > "$dir/back.log"; refused back "a CPU counter went back"
	good | sed 's/^end 1300 500/end 1300 501/' > "$dir/otherpid.log"; refused otherpid "not the app pid"
	good | sed 's/^end \(.*\) 125829120 167772160$/end \1 167772160 125829120/' > "$dir/maxbelow.log"; refused maxbelow "lifetime maximum is below"
	{ good; echo 'spawn soon 9 500 "/Library/k3sm/k3sm"'; } > "$dir/spawntime.log"; refused spawntime "must be whole numbers"
	{ good; echo "spawn 1001 9 500"; } > "$dir/spawnshort.log"; refused spawnshort "spawn wants"
	# A path that is not a JSON string is how a raw newline would forge a record.
	{ good; echo "spawn 1201 510 500 /Library/k3sm/k3sm"; } > "$dir/rawpath.log"; refused rawpath "spawn path must be a JSON string"
	{ good; echo "cpu 12"; } > "$dir/unknown.log"; refused unknown "unknown record cpu"
	good | sed 's/^state .*/state has space/' > "$dir/label.log"; refused label "state wants one label"
	good | sed 's/^pods 12/pods many/' > "$dir/pods.log"; refused pods "pods wants a whole number or unknown"
	good | sed 's/^window 300/window 0/' > "$dir/window.log"; refused window "window wants a positive"

	# Unknown counts are kept as unknown.
	good | sed 's/^pods 12/pods unknown/' > "$dir/unknownpods.log"
	aggregate "$dir/unknownpods.log" | grep -q ' pods=unknown nodes=2$' || die "self-test: unknown pods not kept"
	n=$((n + 1))

	# The eslogger conversion keeps time, pid, parent pid and path, never the
	# arguments.
	if [ -x /usr/bin/jq ]; then
		local line
		line="$(printf '%s\n' '{"time":"2026-10-16T10:00:00.123456789Z","event":{"exec":{"args":["k3sm","kubectl","get","secret"],"target":{"audit_token":{"pid":501},"ppid":500,"executable":{"path":"/Library/k3sm/k3sm"}}}}}' | es_lines)"
		[ "$line" = 'spawn 1792144800 501 500 "/Library/k3sm/k3sm"' ] || die "self-test: eslogger line converted to \"$line\""
		n=$((n + 1))
		# A newline in a path stays escaped inside one record.
		line="$(printf '%s\n' '{"time":"2026-10-16T10:00:00Z","event":{"exec":{"target":{"audit_token":{"pid":509},"ppid":500,"executable":{"path":"/tmp/x\nspawn 1 2 500 /Library/k3sm/k3sm"}}}}}' | es_lines)"
		[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ] || die "self-test: a newline in a path split the record"
		[ "$line" = 'spawn 1792144800 509 500 "/tmp/x\nspawn 1 2 500 /Library/k3sm/k3sm"' ] || die "self-test: newline path converted to \"$line\""
		n=$((n + 1))
	else
		die "self-test: /usr/bin/jq is missing"
	fi

	# The capture filter keeps the app's tree and any k3sm or kubectl exec,
	# and drops every other exec on the Mac.
	local kept
	kept="$(capture_filter 500 <<'EOF'
spawn 1 601 500 "/usr/bin/true"
spawn 2 602 601 "/bin/sh"
spawn 3 603 77 "/usr/bin/ssh"
spawn 4 604 77 "/Library/k3sm/k3sm"
spawn 5 605 77 "/opt/tools/kubectl"
spawn 6 606 1 "/Applications/Other.app/Contents/MacOS/Other"
spawn 7 601 500 "/Library/k3sm/k3sm"
EOF
)"
	[ "$kept" = 'spawn 1 601 500 "/usr/bin/true"
spawn 2 602 601 "/bin/sh"
spawn 4 604 77 "/Library/k3sm/k3sm"
spawn 5 605 77 "/opt/tools/kubectl"
spawn 7 601 500 "/Library/k3sm/k3sm"' ] || die "self-test: capture filter kept:
$kept"
	n=$((n + 1))

	# The output directory: created 0700; an existing one of ours that is
	# group- or other-writable is refused; a file in its place is refused.
	( check_out "$dir/out-new" ) || die "self-test: a new output directory was refused"
	[ "$(stat -f '%Lp' "$dir/out-new")" = 700 ] || die "self-test: the output directory is not 0700"
	( check_out "$dir/out-new" ) || die "self-test: our own 0700 directory was refused"
	mkdir "$dir/out-open" && chmod 770 "$dir/out-open"
	if ( check_out "$dir/out-open" ) 2> /dev/null; then die "self-test: a group-writable output directory was accepted"; fi
	chmod 707 "$dir/out-open"
	if ( check_out "$dir/out-open" ) 2> /dev/null; then die "self-test: an other-writable output directory was accepted"; fi
	: > "$dir/out-file"
	if ( check_out "$dir/out-file" ) 2> /dev/null; then die "self-test: a file was accepted as the output directory"; fi
	n=$((n + 4))

	echo "measure-polls self-test: $n cases ok"
}

case "${1:-}" in
--self-test) self_test ;;
--aggregate) [ $# -eq 2 ] || usage; aggregate "$2" ;;
--state | --out | --window | --pid | --cli) measure "$@" ;;
*) usage ;;
esac
