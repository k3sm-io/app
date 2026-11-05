/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/// AppSwapRootExit names the exit statuses of the administrator path for the
/// app swap (`AppSwapRootScriptBuilder`): the script's own refusals and the
/// installed helper's root mode (`--admin-swap`). They sit above every other
/// root step's (`CopyOutExit` 64 to 77, `LifecycleExit` 100, 101 and 110,
/// `BundledRollExit` 102 to 105), so a status names one cause, and below
/// 126, 127 and 128 and up, which `sh` uses for a command it could not run,
/// one it could not find and a signal. The copy of the installed bundle at
/// the start exits with `CopyOutExit`'s statuses.
public enum AppSwapRootExit {
    /// `/Applications` or `/Applications/k3sm.app` is a symlink, missing or
    /// not a directory; or the target was replaced between the check and the
    /// swap, and the swap was undone. Nothing else was renamed.
    public static let targetRefused: Int32 = 120
    /// The installed bundle's helper is missing from the verified copy, not a
    /// regular file, or fails the helper requirement. Nothing ran.
    public static let helperRejected: Int32 = 121
    /// No user owns the console, or that user has no usable home folder.
    public static let noConsoleUser: Int32 = 122
    /// The staged bundle under the console user's home is missing, a symlink,
    /// below a symlink, holds an unsafe entry, or could not be copied.
    public static let stagedRefused: Int32 = 123
    /// The installed bundle or the copy of the staged one failed
    /// verification: the requirement, the bundle id, the team stamp, or a
    /// `K3smPayloadTag` strictly above the installed bundle's.
    public static let verificationFailed: Int32 = 124
    /// The root-owned work directory is not private to root or not on the
    /// target's volume (`statfs` `f_fsid`), the volume cannot swap two names
    /// in one step, or the rename crossed volumes again after the retry.
    public static let volumeRefused: Int32 = 125
    /// The rename failed with another errno; the old bundle is in place.
    public static let swapFailed: Int32 = 118
    /// The helper was not run as root, from a root-owned copy, with exactly
    /// `--admin-swap`.
    public static let refusedInvocation: Int32 = 119
    /// The installed bundle's tree holds an entry that is a symlink, a
    /// special file, a hard link, setuid, setgid, group or other writable, or
    /// flagged; or root's floor record (`AppSwapRoot.floorRecord`) exists but
    /// is not a root-owned 0600 regular file holding one release tag; or the
    /// installed bundle is older than that record, or is another account's
    /// and carries no release tag or one below
    /// `AppSwapRoot.minimumAdoptedRelease`. A tree another account owns is
    /// not itself a refusal: the swap replaces it with root's copy.
    public static let targetUntrusted: Int32 = 115
    /// A swap had to be undone (the target was replaced between the check and
    /// the rename, or the swapped bundle failed verification) and the undo
    /// rename failed: the copy of the staged bundle is live at the target and
    /// the bundle that came out is kept in root's work directory. The log
    /// names both.
    public static let undoFailed: Int32 = 116
}

/// AppSwapRoot is every fixed fact of the administrator path for the app
/// swap, the fallback when the user-side helper's rename is refused (`EPERM`
/// from App Management, or `EACCES` for a standard user). Nothing in it is
/// read from the user's request file, an argument or the environment:
///
/// - the target is the constant `/Applications/k3sm.app`;
/// - the staged bundle is the console user's home (from the console owner's
///   passwd entry) plus `stagedRelativePath`;
/// - only the installed bundle's own helper runs as root, from the verified
///   root-owned copy the script makes, with the one argument `argument`;
/// - root's work and previous directories sit under the copy-out staging
///   root. Every root step sweeps that root when it starts, except the
///   previous directory, which only the swap engine clears.
public enum AppSwapRoot {
    /// The one target, the constant of operator ruling R6.
    public static let target = "/Applications/k3sm.app"
    /// The directory the target sits in.
    public static let applicationsDirectory = "/Applications"
    /// The bundle's name in the target directory and in every copy.
    public static let bundleName = "k3sm.app"
    /// The helper inside a bundle, relative to the bundle root.
    public static let helperPath = "Contents/Helpers/k3sm-app-update"
    /// The helper's one argument in its root mode.
    public static let argument = "--admin-swap"
    /// The helper's user-side mode that launches the swapped app and waits
    /// for its handshake.
    public static let relaunchArgument = "--relaunch"
    /// Where the app leaves the verified update for this path, relative to
    /// the console user's home.
    public static let stagedRelativePath = "Library/Application Support/io.k3sm.app/admin-staging/k3sm.app"
    /// The user-side helper copy the relaunch runs, relative to the console
    /// user's home (`SwapPaths.helperCopyPath`).
    public static let userHelperRelativePath = "Library/Application Support/io.k3sm.app/update/k3sm-app-update"
    /// The `mktemp -d` template of the script's stage, which holds the
    /// verified copy of the installed bundle and so its helper.
    public static let stagingTemplate = CopyOutPlan.stagingRoot + "/app-swap-helper.XXXXXXXX"
    /// The prefix of every path the root helper may run from.
    public static let helperStagePrefix = CopyOutPlan.stagingRoot + "/app-swap-helper."
    /// The root-owned 0700 directory the staged bundle is copied into, on
    /// the target's volume.
    public static let workRoot = CopyOutPlan.stagingRoot + "/app-swap"
    /// The previous directory's name in the staging root. The root steps'
    /// sweep leaves it out (`RootScriptBuilder.stagedCopy`).
    static let previousDirectoryName = "app-previous"
    /// The root-owned 0700 directory the replaced bundle moves to, named
    /// `k3sm-<tag>.previous`. It can be a tree another account owns, so the
    /// shell sweep leaves it alone: the next swap clears it by descriptor
    /// (`AdminSwapEngine.clearUserLockingFlags`), and `k3sm uninstall` removes
    /// the staging root with it.
    public static let previousRoot = CopyOutPlan.stagingRoot + "/" + previousDirectoryName
    /// Root's record of the highest release this path has installed: a
    /// root-owned 0600 regular file holding one release tag and a newline
    /// (`v1.2.3\n`), written only after a swap is verified. The version floor
    /// is the higher of it and the installed bundle's tag, so a bundle placed
    /// at the target by anyone who can write `/Applications` cannot lower it.
    /// It sits beside the staging root, not in it, because every root step
    /// sweeps the staging root when it starts.
    public static let floorRecord = "/Library/k3sm.app-floor"
    /// The lowest release whose helper the administrator path runs as root
    /// from a target another account owns: the first release that can replace
    /// such a tree. Anyone who can write `/Applications` chooses what is
    /// there, so without this a genuine older release, with its older helper,
    /// would be theirs to pick on a Mac with a low floor or none. It sits
    /// just above the last release published before that helper, so the first
    /// release carrying it passes, whichever number it takes. It is compiled
    /// into the app that renders the script, not read from the bundle checked.
    public static let minimumAdoptedRelease = "v0.2.4-rc.0"
    /// The device whose owner is the console user.
    public static let consoleDevice = "/dev/console"

    /// The command line that relaunches the app in the console user's
    /// session: `launchctl asuser <uid>` puts it in that user's bootstrap
    /// namespace, `sudo -u '#<uid>'` drops root, and the user's own helper
    /// copy runs `--relaunch`, which launches the target and waits for the
    /// handshake. Nothing in it runs as root after `sudo`.
    public static func relaunchArguments(uid: UInt32, home: String) -> [String] {
        ["/bin/launchctl", "asuser", String(uid), "/usr/bin/sudo", "-n", "-u", "#\(uid)", "--",
         home + "/" + userHelperRelativePath, relaunchArgument]
    }
}

/// AppSwapRootScriptBuilder renders the administrator path's root step: a
/// closed verb that takes no path and no text from the app. In order, the
/// script
///
///  1. sets up the copy-out log and refuses a symlinked or missing
///     `/Applications` or target (the `beforeCopy` lines, before anything is
///     copied);
///  2. copies the installed bundle at the constant target into a fresh
///     root-owned 0700 stage and verifies the copy against the app
///     requirement (`RootScriptBuilder.stagedCopy`, the copy-out's own text:
///     no extended attributes, no symlink, special, setuid or writable
///     entry, chowned to root);
///  3. compares the copy's release tag with root's floor, and when the
///     target is another account's, a copy dragged from the disk image, seeds
///     the floor and holds the copy to a compiled minimum (`adoption`);
///  4. refuses unless the copy's helper is a regular file that satisfies the
///     helper requirement;
///  5. runs that helper as root with `--admin-swap`, which does the swap
///     (`AdminSwapEngine` in the swap engine) and the relaunch. The bundle it
///     puts at the target is root's, whoever owned the one it replaces, so
///     the next swap finds a tree that is root's alone.
///
/// The new release's code never runs as root: the only root code is the
/// helper of the bundle already installed. The script reads no stdin, keeps
/// no output and holds the copy-out lock; its stage is removed on every
/// exit path.
public enum AppSwapRootScriptBuilder {
    /// The administrator prompt. Fixed text.
    public static let prompt = "k3sm wants to replace k3sm.app in Applications with the update it downloaded and verified."

    /// The script for the team this build pins: the shipped paths, root as
    /// the owner.
    public static func render(teamID: TeamID) -> RootScript {
        render(teamID: teamID, root: .system, owner: 0)
    }

    /// The script with every absolute path under `root` and `owner` in place
    /// of root. Internal: only the tests render it over a scratch root, to
    /// run it as this account with stub tools; `render(teamID:)` is the one
    /// the app can call.
    static func render(teamID: TeamID, root: ScriptRoot, owner: UInt32) -> RootScript {
        let q = ShellQuote.quote
        let r = root
        let helper = RootScriptBuilder.stagedBundle + "/" + q(AppSwapRoot.helperPath)
        let check = targetCheck(applications: r(AppSwapRoot.applicationsDirectory), target: r(AppSwapRoot.target),
                                floorRecord: r(AppSwapRoot.floorRecord), owner: owner, root: r)
        let text = RootScriptBuilder.stagedCopy(bundlePath: r(AppSwapRoot.target), stagingTemplate: r(AppSwapRoot.stagingTemplate),
                                                designatedRequirement: AppUpdateTrust.appRequirement(teamID: teamID),
                                                beforeCopy: check, root: r)
            + floorCompare(root: r) + adoption(record: r(AppSwapRoot.floorRecord), owner: owner, root: r) + #"""
            helper=\#(helper)
            if [ -L "$helper" ] || [ ! -f "$helper" ]; then
            	echo 'app-swap: refused: the installed helper is missing or not a regular file'
            	exit \#(AppSwapRootExit.helperRejected)
            fi
            \#(r("/bin/chmod")) 0500 "$helper"
            if ! \#(r("/usr/bin/codesign")) --verify --strict \#(q("-R=" + AppUpdateTrust.helperRequirement(teamID: teamID))) "$helper"; then
            	echo 'app-swap: refused: the installed helper is not signed by the k3sm Developer ID'
            	exit \#(AppSwapRootExit.helperRejected)
            fi
            echo 'app-swap: running the installed helper as root'
            "$helper" \#(q(AppSwapRoot.argument))

            """#
        return RootScriptBuilder.stagedStep(text: text, prompt: prompt, readsInput: false)
    }

    /// The target check, before anything is copied, at the shipped paths
    /// with root as the owner.
    static let targetCheck = targetCheck(applications: AppSwapRoot.applicationsDirectory, target: AppSwapRoot.target,
                                         floorRecord: AppSwapRoot.floorRecord, owner: 0)

    /// The target check, before anything is copied. Run by root, as a layer
    /// the installed bundle's own version cannot skip, since its helper is
    /// what runs next:
    ///
    /// - `/Applications` and the target must be real directories, not
    ///   symlinks (`targetRefused`);
    /// - no entry of the target's tree may be group or other writable, carry
    ///   an ACL, or be anything but a regular file or a directory, nor a file
    ///   with more than one link: `isSafeTree`'s rules, the engine's own
    ///   check (`targetUntrusted`). An entry that is not `owner`'s is no
    ///   refusal, since a release dragged from the disk image belongs to
    ///   whoever dragged it and only its verified copy is ever run; the first
    ///   such entry is kept in `$foreign`, empty for a tree that is `owner`'s
    ///   alone, for `adoption`;
    /// - root's floor record, when present, must be a regular file, not a
    ///   symlink, `owner`'s, mode 0600, one link, at most 128 bytes, and hold
    ///   one release tag and a newline (`targetUntrusted`). Its tag is kept
    ///   in `$floor`, empty when there is no record, for `floorCompare`.
    ///
    /// These checks are a subset of the engine's (`isSafeTree`): they do not
    /// look for setuid or setgid bits or file flags. The staged copy's own
    /// check after the copy (`find -perm +6022`, `refusedTree`) and the
    /// engine cover those. The record's checks rest on `/Library`, its
    /// parent, being root's and not writable by others; a record moved
    /// elsewhere needs that parent check here too.
    ///
    /// The helper checks the target again, by descriptor, before and after
    /// the swap. `applications`, `target`, `floorRecord` and `owner` are the
    /// shipped constants and root; tests render it over scratch paths.
    static func targetCheck(applications: String, target: String, floorRecord: String, owner: UInt32,
                            root: ScriptRoot = .system) -> String {
        let q = ShellQuote.quote
        let r = root
        return tagRank(root: r) + #"""
            apps=\#(q(applications))
            target=\#(q(target))
            if [ -L "$apps" ] || [ ! -d "$apps" ] || [ -L "$target" ] || [ ! -d "$target" ]; then
            	echo 'app-swap: refused: Applications or k3sm.app in it is a symlink or not a folder'
            	exit \#(AppSwapRootExit.targetRefused)
            fi
            if ! foreign=$(\#(r("/usr/bin/find")) "$target" ! -user \#(owner) -print -quit); then
            	echo 'app-swap: refused: k3sm.app in Applications could not be read'
            	exit \#(AppSwapRootExit.targetUntrusted)
            fi
            if ! bad=$(\#(r("/usr/bin/find")) "$target" \( -perm +022 -o -acl -o ! \( -type f -o -type d \) -o \( -type f -links +1 \) \) -print -quit); then
            	echo 'app-swap: refused: k3sm.app in Applications could not be read'
            	exit \#(AppSwapRootExit.targetUntrusted)
            fi
            if [ -n "$bad" ]; then
            	echo 'app-swap: refused: k3sm.app holds an entry writable by group or others, with an ACL, or not a plain file or folder'
            	exit \#(AppSwapRootExit.targetUntrusted)
            fi
            record=\#(q(floorRecord))
            floor=
            if [ -e "$record" ] || [ -L "$record" ]; then
            	if [ -L "$record" ] || [ ! -f "$record" ] || [ "$(\#(r("/usr/bin/stat")) -f '%u %Lp %l' "$record")" != '\#(owner) 600 1' ] || [ "$(\#(r("/usr/bin/stat")) -f %z "$record")" -gt \#(floorRecordLimit) ]; then
            		echo 'app-swap: refused: the floor record is not a root-owned 0600 file'
            		exit \#(AppSwapRootExit.targetUntrusted)
            	fi
            	tag=$(\#(r("/bin/cat")) "$record")
            	if [ "$(\#(r("/usr/bin/stat")) -f %z "$record")" != "$((${#tag} + 1))" ] || ! tagrank > /dev/null; then
            		echo 'app-swap: refused: the floor record does not hold one release tag'
            		exit \#(AppSwapRootExit.targetUntrusted)
            	fi
            	floor=$tag
            fi

            """#
    }

    /// The largest floor record the script reads, the engine's
    /// `AdminSwapEngine.floorRecordLimit`.
    static let floorRecordLimit = 128

    /// The shell function `tagrank`: prints a sortable rank of the release
    /// tag in `$tag` (MAJOR, MINOR and PATCH as nine digits each, then the
    /// release candidate number as five, 99999 for a release, so a release
    /// ranks above its candidates), or fails when `$tag` is not a release tag
    /// (`AppVersion.releaseTagVersion`'s grammar: `v` then three numbers of
    /// one to nine digits with no leading zero, and an optional `-rc.N` with
    /// N one to four digits, no leading zero). The engine's floor rule is
    /// `SemanticVersion`'s order; `appSwapScriptTagRankAgreesWithTheEngine`
    /// pins that the two accept the same tags and order them alike.
    static let tagRank = tagRank(root: .system)

    /// `tagRank` with its tool under `root`.
    static func tagRank(root: ScriptRoot) -> String {
        let r = root
        return #"""
        tagrank() {
        	case $tag in ''|*[!0-9a-z.-]*) return 1 ;; esac
        	printf '%s\n' "$tag" | \#(r("/usr/bin/grep")) -Eqx 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?' || return 1
        	core=${tag#v}
        	rc=99999
        	case $core in *-rc.*) rc=${core#*-rc.}; core=${core%%-*} ;; esac
        	major=${core%%.*}
        	rest=${core#*.}
        	printf '%09d%09d%09d%05d\n' "$major" "${rest%%.*}" "${rest#*.}" "$rc"
        }

        """#
    }

    /// After the installed bundle's copy verifies, and before its helper
    /// runs: with a floor record, the copy's `K3smPayloadTag` must be a
    /// release tag at or above it (`targetUntrusted`), so an older release
    /// put back at the target never has its helper run as root. The engine
    /// then requires the staged bundle strictly above the higher of the two.
    static let floorCompare = floorCompare(root: .system)

    /// `floorCompare` with its tools under `root`.
    static func floorCompare(root: ScriptRoot) -> String {
        let r = root
        return #"""
        if [ -n "$floor" ]; then
        	tag=$floor
        	floorrank=$(tagrank)
        	tag=$(\#(r("/usr/bin/plutil")) -extract K3smPayloadTag raw -o - "$stage"/\#(ShellQuote.quote(CopyOutPlan.stagedBundleName))/'Contents/Info.plist' 2>/dev/null) || tag=
        	if ! installedrank=$(tagrank); then
        		echo 'app-swap: refused: the installed k3sm.app carries no release tag'
        		exit \#(AppSwapRootExit.targetUntrusted)
        	fi
        	if [ "$(\#(r("/usr/bin/awk")) -v a="$installedrank" -v b="$floorrank" 'BEGIN { print ("" a < "" b) }')" != 0 ]; then
        		echo 'app-swap: refused: the installed k3sm.app is older than the release root installed last'
        		exit \#(AppSwapRootExit.targetUntrusted)
        	fi
        fi

        """#
    }

    /// After `floorCompare`, and before the helper runs: when the target's
    /// tree is another account's (`$foreign`), the owner of that tree chose
    /// the copy whose helper is about to run as root, and the engine has no
    /// root-owned bundle to read a floor from. So:
    ///
    /// - with no record, the seed writes the higher of the verified copy's
    ///   tag and `AppSwapRoot.minimumAdoptedRelease` (`AppSwapFloor.seed`);
    /// - with a record or without, a copy with no release tag, or one below
    ///   the minimum, is refused (`targetUntrusted`).
    ///
    /// The seed comes first, so it stands when the copy is refused here or the
    /// helper refuses later: that account can raise the floor with a genuine
    /// newer release, and an older one is then refused until an administrator
    /// runs `AppSwapFloor.resetCommand`. The README states this. A tree that
    /// is `owner`'s alone skips all of it.
    static func adoption(record: String, owner: UInt32, root: ScriptRoot = .system,
                         minimum: String = AppSwapRoot.minimumAdoptedRelease) -> String {
        let r = root
        return #"""
        if [ -n "$foreign" ]; then
        \#(AppSwapFloor.seed(record: record, owner: owner, root: root, minimum: minimum))	tag=$(\#(r("/usr/bin/plutil")) -extract K3smPayloadTag raw -o - "$stage"/\#(ShellQuote.quote(CopyOutPlan.stagedBundleName))/'Contents/Info.plist' 2>/dev/null) || tag=
        	if ! copyrank=$(tagrank); then
        		echo 'app-swap: refused: k3sm.app in Applications is not owned by root and carries no release tag'
        		exit \#(AppSwapRootExit.targetUntrusted)
        	fi
        	tag=\#(ShellQuote.quote(minimum))
        	if [ "$(\#(r("/usr/bin/awk")) -v a="$copyrank" -v b="$(tagrank)" 'BEGIN { print ("" a < "" b) }')" != 0 ]; then
        		echo 'app-swap: refused: k3sm.app in Applications is not owned by root and is older than the lowest release this path accepts from it'
        		exit \#(AppSwapRootExit.targetUntrusted)
        	fi
        	echo 'app-swap: k3sm.app in Applications is not owned by root; the swap replaces it with a copy root owns'
        fi

        """#
    }
}
