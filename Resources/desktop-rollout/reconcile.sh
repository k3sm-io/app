#!/bin/bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
# Run only from the enrolled user's Aqua session. Every executable and input
# besides the pinned registry artifact comes from this bundle or local enrollment.
set -euo pipefail
umask 077
export PATH=/Library/k3sm:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
unset BASH_ENV ENV CDPATH
assets=$(cd -P -- "$(dirname "$0")" && pwd -P)
config=$1
private=$2
uid=$(/usr/bin/id -u)
[[ $uid != 0 && $(/usr/bin/stat -f %u /dev/console) == "$uid" ]]
owned() {
    [[ -e $1 && ! -L $1 && $(/usr/bin/stat -f %u "$1") == "$uid" ]] || return 1
    local mode
    mode=$(/usr/bin/stat -f %Lp "$1")
    (( (8#$mode & 022) == 0 ))
}
safe_dir() { [[ -d $1 && $1 == /* && $(cd -P -- "$1" && pwd -P) == "$1" ]] && owned "$1"; }
# Mode bits alone miss inherited macOS ACL rights. Check the entire chain:
# a writable parent can rename or delete an otherwise read-only receipt root.
safe_chain() {
    local path=$1 owner mode rules
    while :; do
        [[ ! -L $path ]] || return 1
        owner=$(/usr/bin/stat -f %u "$path")
        mode=$(/usr/bin/stat -f %Lp "$path")
        [[ $owner == 0 || $owner == "$uid" ]] && (( (8#$mode & 022) == 0 )) || return 1
        rules=$(/bin/ls -lde "$path") || return 1
        if printf '%s\n' "$rules" | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:.* allow .*([Ww]rite|append|add_file|add_subdirectory|delete|chown|all)'; then return 1; fi
        [[ $path != / ]] || break
        path=$(/usr/bin/dirname "$path")
    done
}
private_dir() {
    safe_dir "$1" && safe_chain "$1" && [[ $(/usr/bin/stat -f %Lp "$1") == 700 ]] || return 1
    ! /bin/ls -lde "$1" | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:.* allow '
}
private_dir "$private"
safe_dir "$(dirname "$config")"
owned "$config"
safe_chain "$config"
value() { /usr/bin/jq -er "$1" "$config"; }
name=$(value .deployment)
node=$(value .node)
bundle=$(value .bundleID)
app=$(value .bundleName)
repo=$(value .repository)
receipts=$(value .receiptsRoot)
[[ $(value .uid) == "$uid" ]]
[[ $name =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && $node =~ ^[a-z0-9][a-z0-9.-]{0,251}$ ]]
[[ $bundle =~ ^[A-Za-z0-9.-]+$ && $app =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*\.app$ ]]
[[ $bundle != io.k3sm.app && $repo =~ ^apps/[a-z0-9]+([._/-][a-z0-9]+)*$ ]]
safe_dir "$receipts"
safe_chain "$receipts"
[[ $receipts != "$private" && $receipts != "$private/"* && $private != "$receipts/"* ]]
work="$private/$name"
mkdir -p -m 700 "$work"
private_dir "$work"
if [[ ${3:-} != locked ]]; then
    exec /usr/bin/lockf -t 0 -k "$work/reconcile.lock" /bin/bash "$0" "$config" "$private" locked
fi
receipt="$receipts/$name.json"
tmp=$(mktemp -d "$work/.check.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
cli=/Library/k3sm/k3sm
kube() { "$cli" kubectl --request-timeout=5s -n k3sm-desktop "$@"; }
if ! kube get ds "$name" -o json > "$tmp/ds" ||
   ! kube get pods --field-selector "spec.nodeName=$node" -l "k3sm.io/desktop-app=$name" -o json > "$tmp/pods"; then
    rm -f -- "$receipt"; exit 1
fi
owner=$(/usr/bin/jq -er '.metadata | select(.deletionTimestamp == null) | .uid' "$tmp/ds") || { rm -f -- "$receipt"; exit 1; }
if ! /usr/bin/jq -e --slurpfile ds "$tmp/ds" --arg node "$node" --arg name "$name" --arg bundle "$bundle" \
    -f "$assets/desired.jq" "$tmp/pods" > "$tmp/desired"; then
    rm -f -- "$receipt"; exit 0
fi
pod=$(/usr/bin/jq -er .podUID "$tmp/desired")
ref=$(/usr/bin/jq -er .artifact "$tmp/desired")
digest=${ref#*@}
if [[ ! $pod =~ ^[[:alnum:]-]{1,80}$ || $ref != "$repo@$digest" || ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
    rm -f -- "$receipt"; exit 1
fi
matches_template() {
    /usr/bin/jq -e --arg owner "$owner" --arg ref "$ref" --arg bundle "$bundle" --arg name "$name" '
        .metadata.uid==$owner and .metadata.deletionTimestamp==null and
        .spec.template.metadata.labels["k3sm.io/desktop-app"]==$name and
        .spec.template.metadata.annotations["k3sm.io/app-artifact"]==$ref and
        .spec.template.metadata.annotations["k3sm.io/app-bundle-id"]==$bundle' >/dev/null
}
matches_template < "$tmp/ds" || { rm -f -- "$receipt"; exit 1; }
podname=$(/usr/bin/jq -er .podName "$tmp/desired")
still_desired() {
    [[ $(/usr/bin/stat -f %u /dev/console) == "$uid" ]] &&
    kube get ds "$name" -o json | matches_template &&
    kube get pod "$podname" -o json | /usr/bin/jq -e --arg u "$pod" --arg r "$ref" --arg b "$bundle" '
        .metadata.uid==$u and .metadata.deletionTimestamp==null and
        .metadata.annotations["k3sm.io/app-artifact"]==$r and .metadata.annotations["k3sm.io/app-bundle-id"]==$b' >/dev/null
}
revision="$work/${digest#sha256:}"
candidate="$revision/$app"
peer() { /usr/bin/osascript -l JavaScript "$assets/peer.js" "$1" "$bundle" "$2" "${3:-}"; }
healthy() {
    local pid
    pid=$(peer "${2:-inspect}" "$1") || return 1
    [[ $pid =~ ^[1-9][0-9]*$ && $(/bin/ps -p "$pid" -o uid= | tr -d ' ') == "$uid" ]] || return 1
    /usr/bin/codesign --verify "+$pid" || return 1
    local running_hash signed_hash
    running_hash=$(/usr/bin/codesign -dvvv "+$pid" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
    signed_hash=$(/usr/bin/codesign -dvvv "${3:-$1}" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
    [[ $running_hash =~ ^[0-9a-f]{40}$ && $running_hash == "$signed_hash" ]] || return 1
    printf '%s\n' "$pid"
}
verify() {
    local path=$1 team hash
    [[ -d $path && ! -L $path && $(cd -P -- "$path" && pwd -P) == "$path" ]] || return 1
    [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw "$path/Contents/Info.plist") == "$bundle" ]] || return 1
    /usr/bin/codesign --verify --deep --strict "$path" || return 1
    team=$(value '.teamID // ""' )
    if [[ $team =~ ^[A-Z0-9]{10}$ ]]; then
        /usr/bin/codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"$bundle\"" "$path"
    else
        hash=$(/usr/bin/codesign -dvvv "$path" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        [[ $hash =~ ^[0-9a-f]{40}$ ]] && /usr/bin/jq -e --arg h "$hash" '(.allowedCDHashes // []) | index($h) != null' "$config" >/dev/null
    fi
}
safe_extracted_bundle() {
    local root=$1 link resolved
    [[ -d $root && ! -L $root ]] || return 1
    # Reject device nodes, pipes, hardlinked files and links leaving the sealed bundle.
    /usr/bin/find "$root" ! -type f ! -type d ! -type l -print0 > "$tmp/special" || return 1
    [[ ! -s "$tmp/special" ]] || return 1
    /usr/bin/find "$root" -type f -links +1 -print0 > "$tmp/hardlinks" || return 1
    [[ ! -s "$tmp/hardlinks" ]] || return 1
    /usr/bin/find "$root" -type l -print0 > "$tmp/links" || return 1
    while IFS= read -r -d '' link; do
        resolved=$(/usr/bin/realpath "$link") || return 1
        [[ $resolved == "$root/"* ]] || return 1
    done < "$tmp/links"
}
write_receipt() {
    local target
    target=$(mktemp "$receipts/.receipt.XXXXXXXX")
    /usr/bin/jq -n --arg u "$pod" --arg d "$digest" --arg b "$bundle" --argjson p "$1" \
        '{podUID:$u,digest:$d,bundleID:$b,pid:$p,ready:true}' > "$target"
    chmod 0644 "$target"
    mv -f -- "$target" "$receipt"
}
last="$work/last-good"
previous=$(cat "$last" 2>/dev/null || value '.adoptPath // ""')
if [[ $previous == "$candidate" ]] && pid=$(healthy "$candidate"); then
    # Verify the live bundle's signature before issuing another readiness receipt.
    if verify "$candidate"; then write_receipt "$pid"; exit 0; fi
fi
rm -f -- "$receipt"
[[ ! -f "$work/failed-$pod" ]] || exit 1
if [[ ! -d $revision ]]; then
    /bin/bash "$assets/app-bundle.sh" pull "$ref" "$tmp/archive.zip"
    # bsdtar refuses traversal and extraction through symlinks. Bound ZIP size,
    # member count and declared expanded size before extracting to a private directory.
    totals=$(/usr/bin/unzip -Z -t "$tmp/archive.zip")
    [[ $totals =~ ^([0-9]+)\ files?,\ ([0-9]+)\ bytes\ uncompressed ]] || exit 1
    (( BASH_REMATCH[1] <= 100000 && BASH_REMATCH[2] <= 4294967296 ))
    mkdir "$tmp/expanded"
    (ulimit -f 4194304; /usr/bin/tar --no-same-owner --no-same-permissions -xf "$tmp/archive.zip" -C "$tmp/expanded")
    safe_extracted_bundle "$tmp/expanded/$app"
    verify "$tmp/expanded/$app"
    mkdir "$tmp/version"
    mv "$tmp/expanded/$app" "$tmp/version/"
    mv "$tmp/version" "$revision"
fi
verify "$candidate"
still_desired
rollback=$previous
# During initial adoption the source may still be alive after an interrupted quit.
# Match its running code to the saved private copy before resuming that handoff.
if [[ $previous == "$work/adopt-"* ]] && [[ $(peer inspect "$previous") == foreign ]]; then
    adopted=$(value '.adoptPath // ""')
    if [[ -n $adopted ]] && healthy "$adopted" inspect "$previous" >/dev/null; then previous=$adopted; fi
fi
if ! healthy "$candidate" >/dev/null && [[ -n $previous && $previous != "$candidate" ]]; then
    case "$(peer inspect "$previous")" in
        none) ;;
        [1-9]*)
            verify "$previous"
            if [[ $previous != "$work/"* ]]; then
                # The original launch location can be a shared artifact directory. Keep a
                # separately verified, private copy for rollback before requesting quit.
                hash=$(/usr/bin/codesign -dvvv "$previous" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
                [[ $hash =~ ^[0-9a-f]{40}$ ]]
                rollback="$work/adopt-$hash/$app"
                if [[ ! -d $rollback ]]; then
                    mkdir "$tmp/adopt"
                    /usr/bin/ditto "$previous" "$tmp/adopt/$app"
                    safe_extracted_bundle "$tmp/adopt/$app"
                    verify "$tmp/adopt/$app"
                    mv "$tmp/adopt" "$work/adopt-$hash"
                fi
                verify "$rollback"
            fi
            oldpid=$(healthy "$previous" inspect "$rollback")
            # Persist the verified recovery location before the old process exits.
            printf '%s\n' "$rollback" > "$tmp/good"
            mv -f "$tmp/good" "$last"
            peer terminate "$previous" "$oldpid" >/dev/null
            for ((i=0; i<60; i++)); do [[ $(peer inspect "$previous") == none ]] && break; sleep 0.25; done
            ;;
        *) exit 1 ;;
    esac
fi
if ! pid=$(healthy "$candidate"); then
    [[ $(peer inspect "$candidate") == none ]] || exit 1
    /usr/bin/open -gj -a "$candidate" || true
    for ((i=0; i<30; i++)); do pid=$(healthy "$candidate") && break; sleep 0.5; done
fi
if [[ -n ${pid:-} ]] && sleep 2 && [[ $(healthy "$candidate") == "$pid" ]] && still_desired; then
    printf '%s\n' "$candidate" > "$tmp/good"
    mv -f "$tmp/good" "$last"
    write_receipt "$pid"
else
    touch "$work/failed-$pod"
    if current=$(healthy "$candidate" identity); then peer terminate "$candidate" "$current" >/dev/null; fi
    for ((i=0; i<40; i++)); do [[ $(peer inspect "$candidate") == none ]] && break; sleep 0.25; done
    if [[ -n $rollback && $rollback != "$candidate" && $rollback == "$work/"* && $(peer inspect "$rollback") == none ]] && verify "$rollback"; then
        /usr/bin/open -gj -a "$rollback"
        restored=""
        for ((i=0; i<30; i++)); do restored=$(healthy "$rollback") && break; sleep 0.5; done
        [[ -n $restored ]] && sleep 2 && [[ $(healthy "$rollback") == "$restored" ]] || exit 1
        printf '%s\n' "$rollback" > "$tmp/good"
        mv -f "$tmp/good" "$last"
    fi
    exit 1
fi
