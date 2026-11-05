exec 4>&2
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
# An entry holding anything not root's is left for the swap helper, which
# walks it by descriptor: its former owner may still hold descriptors in
# it. find -x only reads, follows no symlink and stays on this volume.
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
	if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then continue; fi
	if ! left=$(/usr/bin/find -x "$entry" ! -user 0 -print -quit) || [ -n "$left" ]; then
		echo "copy-out: left for the swap helper: ${entry##*/} holds an entry not owned by root"
		continue
	fi
	/usr/bin/chflags -R nouchg,nouappnd "$entry" || true
	/bin/rm -rf "$entry"
done
stage=$(/usr/bin/mktemp -d '/Library/k3sm.staging/bundled-roll.XXXXXXXX')
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
if ! /usr/bin/codesign --verify --strict --deep '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMTEAM12" and identifier "io.k3sm.app"' "$stage"/'k3sm.app'; then
	echo 'copy-out: refused: the app is not signed by the k3sm Developer ID'
	exit 77
fi
bundle="$stage"/'k3sm.app'
tag='v0.3.0'
echo 'bundled-roll: reading the payload record'
record="$bundle"/'Contents/Resources/payload.release'
nl='
'
cr=$(printf '\r')
record_refused() {
	echo "bundled-roll: refused: $1"
	exit 102
}
tag_refused() {
	echo "bundled-roll: refused: $1"
	exit 103
}
check_failed() {
	echo "bundled-roll: refused: $1"
	exit 105
}
if [ -L "$record" ] || [ ! -f "$record" ]; then record_refused 'the payload record is missing, a symlink or not a regular file'; fi
size=$(/usr/bin/stat -f %z "$record") || check_failed 'the payload record could not be measured'
case "$size" in ''|*[!0-9]*) check_failed 'the payload record could not be measured' ;; esac
if [ "$size" -gt 1024 ]; then record_refused 'the payload record is larger than 1024 bytes'; fi
if /usr/bin/grep -q "$cr" "$record"; then
	record_refused 'the payload record holds a carriage return'
else
	st=$?
	if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi
fi
for key in 'tag' 'tarball_sha256' 'payload_manifest_sha256'; do
	n=$(/usr/bin/grep -c "^$key=" "$record") || { st=$?; if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi; }
	if [ "$n" != 1 ]; then record_refused "the payload record holds $n $key lines, not exactly one"; fi
done
record_tag=$(/usr/bin/sed -n 's/^tag=//p' "$record") || check_failed 'the payload record could not be read'
digest=$(/usr/bin/sed -n 's/^tarball_sha256=//p' "$record") || check_failed 'the payload record could not be read'
plist_tag=$(/usr/libexec/PlistBuddy -c 'Print :K3smPayloadTag' "$bundle"/'Contents/Info.plist') || plist_tag=
case "$tag" in *"$nl"*|*"$cr"*) tag_refused 'the release tag holds a line break' ;; esac
if ! printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?$'; then tag_refused 'the release tag is not a release tag'; fi
if [ "$record_tag" != "$tag" ]; then tag_refused 'the payload record names another release'; fi
if [ "$plist_tag" != "$tag" ]; then tag_refused 'the bundle names another release in K3smPayloadTag'; fi
case "$digest" in *"$nl"*|*"$cr"*) digest_ok=no ;; *) digest_ok=yes ;; esac
if [ "$digest_ok" != yes ] || ! printf '%s\n' "$digest" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
	echo 'bundled-roll: refused: the payload record tarball_sha256 is not 64 lowercase hex digits'
	exit 104
fi
echo 'bundled-roll: the payload record matches the release'
set -eu
umask 077
cd /
k3sm='/Library/k3sm/k3sm'
refuse() {
	echo "k3sm app: refused: $1" >&2
	exit 100
}
nl='
'
acl_check() {
	listing=$(/bin/ls -led "$1") || refuse "$1 could not be checked"
	case "${listing%% *}" in *+) refuse "$1 carries an ACL" ;; esac
	case "$listing" in *"$nl"*) refuse "$1 carries an ACL" ;; esac
}
check() {
	bad=$(/usr/bin/find "$1" -maxdepth 0 \( ! -user 0 -o -perm -0020 -o -perm -0002 \) -print) || refuse "$1 could not be checked"
	if [ -n "$bad" ]; then refuse "$1 is not owned by root, or is writable by group or others"; fi
	acl_check "$1"
}
link_target() {
	t=$(/usr/bin/readlink -n "$1" && echo x) || refuse "$1 could not be read"
	t=${t%x}
}
for p in '/' '/Library' '/Library/k3sm'; do
	if [ -L "$p" ]; then refuse "$p is a symlink"; fi
	if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
	check "$p"
done
if [ -L "$k3sm" ]; then
	check "$k3sm"
	link_target "$k3sm"
	if [ "$t" != 'current/k3sm' ]; then refuse "$k3sm is a symlink other than current/k3sm"; fi
	p='/Library/k3sm/current'
	if [ ! -L "$p" ]; then refuse "$p is not a symlink into versions"; fi
	check "$p"
	link_target "$p"
	case "$t" in versions/*) ;; *) refuse "$p does not point into versions" ;; esac
	ver=${t#versions/}
	case "$ver" in
	'' | [!0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]* | *[!0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+_-]* | *.partial)
		refuse "$p names an invalid version" ;;
	unknown-*)
		case "$ver" in
		unknown-[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) refuse "$p names an invalid version" ;;
		esac ;;
	esac
	if [ "${#ver}" -gt 128 ]; then refuse "$p names an invalid version"; fi
	for p in '/Library/k3sm/versions' '/Library/k3sm/versions/'"$ver"; do
		if [ -L "$p" ]; then refuse "$p is a symlink"; fi
		if [ ! -e "$p" ]; then refuse "$p does not exist"; fi
		if [ ! -d "$p" ]; then refuse "$p is not a directory"; fi
		check "$p"
	done
	k3sm='/Library/k3sm/versions/'"$ver"'/k3sm'
	if [ -L "$k3sm" ]; then refuse "$k3sm is a symlink"; fi
fi
if [ ! -e "$k3sm" ]; then refuse "$k3sm does not exist"; fi
check "$k3sm"
if [ ! -f "$k3sm" ]; then refuse "$k3sm is not a regular file"; fi
if ! /usr/bin/codesign --verify --strict '-R=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMTEAM12"' "$k3sm"; then
	echo 'k3sm app: refused: the installed k3sm is not signed by the k3sm Developer ID' >&2
	exit 101
fi
echo 'bundled-roll: running k3sm update apply'
"$k3sm" 'update' 'apply' '--yes' '--version' 'v0.3.0' '--pin-sha256' "$digest" 2>&4
