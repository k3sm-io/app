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
exec "$k3sm" 'network' 'lan' 'on'
