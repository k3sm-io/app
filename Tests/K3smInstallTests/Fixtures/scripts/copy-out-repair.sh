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
	if [ -n "$stage" ]; then /bin/rm -rf "$stage"; fi
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
/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
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
k3sm="$stage"/'k3sm.app'/'Contents/Resources/payload/k3sm'
echo 'copy-out: running k3sm install (repair)'
"$k3sm" 'install' '--from-staging' "$stage"
