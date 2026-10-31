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
dm_off() {
	echo "k3sm app: refused: developer mode is off: $1" >&2
	exit 110
}
dm_nl='
'
dm_held() {
	bad=$(/usr/bin/find "$1" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || dm_off "$1 could not be checked"
	if [ -n "$bad" ]; then dm_off "$1 is not owned by root, or is writable by group or others"; fi
	listing=$(/bin/ls -led "$1") || dm_off "$1 could not be checked"
	case "${listing%% *}" in *+) dm_off "$1 carries an ACL" ;; esac
	case "$listing" in *"$dm_nl"*) dm_off "$1 carries an ACL" ;; esac
}
for p in '/' '/Library'; do
	if [ -L "$p" ]; then dm_off "$p is a symlink"; fi
	if [ ! -d "$p" ]; then dm_off "$p is not a directory"; fi
	dm_held "$p"
done
marker='/Library/k3sm.developer-mode'
if [ -L "$marker" ]; then dm_off "$marker is a symlink"; fi
if [ ! -e "$marker" ]; then dm_off "$marker does not exist"; fi
if [ ! -f "$marker" ]; then dm_off "$marker is not a regular file"; fi
dm_held "$marker"
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
if ! /usr/bin/codesign --verify --strict --deep "$stage"/'k3sm.app'; then
	echo 'copy-out: refused: the app signature is not intact'
	exit 77
fi
k3sm="$stage"/'k3sm.app'/'Contents/Resources/payload/k3sm'
echo 'copy-out: running k3sm install (repair)'
"$k3sm" 'install' '--from-staging' "$stage"
