set -eu
umask 077
cd /
logdir='/Library/Logs/k3sm'
log='/Library/Logs/k3sm/copy-out.log'
if [ -L "$logdir" ] || [ -L "$log" ]; then
	echo 'copy-out: refused: the log path is a symlink' >&2
	exit 64
fi
/bin/mkdir -p "$logdir"
/usr/sbin/chown root:admin "$logdir"
/bin/chmod 0750 "$logdir"
/bin/rm -f "$log"
: > "$log"
/usr/sbin/chown root:admin "$log"
/bin/chmod 0640 "$log"
exec >> "$log" 2>&1
stage=
finish() {
	status=$?
	if [ -n "$stage" ]; then /usr/bin/chflags -R nouchg,nouappnd "$stage" 2>/dev/null || true; /bin/rm -rf "$stage"; fi
	echo "copy-out: exit $status"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM
root='/Library/k3sm.staging'
if [ -L "$root" ]; then
	echo 'copy-out: refused: the staging root is a symlink'
	exit 64
fi
/bin/mkdir -p "$root"
/usr/sbin/chown root:wheel "$root"
/bin/chmod 0700 "$root"
echo 'copy-out: sweeping stale staging entries'
# rm cannot remove a file flagged uchg or uappnd, which a user can set
# on a staged file and ditto keeps; under set -eu that would wedge every
# later root step. Clear them first; a failure falls through to rm.
# Root's previous directory is left out: it can hold a tree an account
# still has a descriptor in, and the swap engine walks it by descriptor.
/usr/bin/find "$root" -mindepth 1 -maxdepth 1 ! -name 'app-previous' -exec /usr/bin/chflags -R nouchg,nouappnd {} + || true
/usr/bin/find "$root" -mindepth 1 -maxdepth 1 ! -name 'app-previous' -exec /bin/rm -rf {} +
stage=$(/usr/bin/mktemp -d '/Library/k3sm.staging/0.2.0.XXXXXXXX')
/usr/sbin/chown root:wheel "$stage"
/bin/chmod 0700 "$stage"
echo 'copy-out: copying the app bundle'
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl '/Applications/k3sm.app' "$stage"/'k3sm.app'
bad=$(/usr/bin/find "$stage"/'k3sm.app' \( ! \( -type f -o -type d \) -o -perm +6022 \) -print | /usr/bin/head -n 1)
if [ -n "$bad" ]; then
	echo "copy-out: refused: $bad is a symlink, a special file, setuid or setgid, or writable by group or others"
	exit 65
fi
/usr/sbin/chown -R root:wheel "$stage"/'k3sm.app'
echo 'copy-out: verifying the signature'
if ! /usr/bin/codesign --verify --strict --deep '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMTEAM12"' "$stage"/'k3sm.app'; then
	echo 'copy-out: refused: the app is not signed by the k3sm Developer ID'
	exit 77
fi
tagrank() {
	case $tag in ''|*[!0-9a-z.-]*) return 1 ;; esac
	printf '%s\n' "$tag" | /usr/bin/grep -Eqx 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?' || return 1
	core=${tag#v}
	rc=99999
	case $core in *-rc.*) rc=${core#*-rc.}; core=${core%%-*} ;; esac
	major=${core%%.*}
	rest=${core#*.}
	printf '%09d%09d%09d%05d\n' "$major" "${rest%%.*}" "${rest#*.}" "$rc"
}
record='/Library/k3sm.app-floor'
if [ ! -e "$record" ] && [ ! -L "$record" ]; then
	tag=$(/usr/bin/plutil -extract K3smPayloadTag raw -o - "$stage"/'k3sm.app'/'Contents/Info.plist' 2>/dev/null) || tag=
	if tagrank > /dev/null; then
		printf '%s\n' "$tag" > "$stage"/'app-floor'
		/usr/sbin/chown 0 "$stage"/'app-floor'
		/bin/chmod 0600 "$stage"/'app-floor'
		/bin/mv -f "$stage"/'app-floor' "$record"
		echo "copy-out: recorded $tag as the app release floor"
	fi
fi
k3sm="$stage"/'k3sm.app'/'Contents/Resources/payload/k3sm'
echo 'copy-out: running k3sm install (update)'
"$k3sm" 'install' '--from-staging' "$stage" '--user' 'alice'
