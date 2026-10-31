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
///   root, which every root step sweeps when it starts.
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
    /// The root-owned 0700 directory the replaced bundle moves to, named
    /// `k3sm-<tag>.previous`. The next root step's sweep removes it.
    public static let previousRoot = CopyOutPlan.stagingRoot + "/app-previous"
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
///  3. refuses unless the copy's helper is a regular file that satisfies the
///     helper requirement;
///  4. runs that helper as root with `--admin-swap`, which does the swap
///     (`AdminSwapEngine` in the swap engine) and the relaunch.
///
/// The new release's code never runs as root: the only root code is the
/// helper of the bundle already installed. The script reads no stdin, keeps
/// no output and holds the copy-out lock; its stage is removed on every
/// exit path.
public enum AppSwapRootScriptBuilder {
    /// The administrator prompt. Fixed text.
    public static let prompt = "k3sm wants to replace k3sm.app in Applications with the update it downloaded and verified."

    /// The script for the team this build pins.
    public static func render(teamID: TeamID) -> RootScript {
        let q = ShellQuote.quote
        let helper = RootScriptBuilder.stagedBundle + "/" + q(AppSwapRoot.helperPath)
        let text = RootScriptBuilder.stagedCopy(bundlePath: AppSwapRoot.target, stagingTemplate: AppSwapRoot.stagingTemplate,
                                                designatedRequirement: AppUpdateTrust.appRequirement(teamID: teamID),
                                                beforeCopy: targetCheck)
            + #"""
            helper=\#(helper)
            if [ -L "$helper" ] || [ ! -f "$helper" ]; then
            	echo 'app-swap: refused: the installed helper is missing or not a regular file'
            	exit \#(AppSwapRootExit.helperRejected)
            fi
            /bin/chmod 0500 "$helper"
            if ! /usr/bin/codesign --verify --strict \#(q("-R=" + AppUpdateTrust.helperRequirement(teamID: teamID))) "$helper"; then
            	echo 'app-swap: refused: the installed helper is not signed by the k3sm Developer ID'
            	exit \#(AppSwapRootExit.helperRejected)
            fi
            echo 'app-swap: running the installed helper as root'
            "$helper" \#(q(AppSwapRoot.argument))

            """#
        return RootScriptBuilder.stagedStep(text: text, prompt: prompt, readsInput: false)
    }

    /// The target check, before anything is copied: `/Applications` and the
    /// target must be real directories, not symlinks. The helper checks
    /// again, by descriptor, before and after the swap.
    static let targetCheck: String = {
        let q = ShellQuote.quote
        return #"""
            apps=\#(q(AppSwapRoot.applicationsDirectory))
            target=\#(q(AppSwapRoot.target))
            if [ -L "$apps" ] || [ ! -d "$apps" ] || [ -L "$target" ] || [ ! -d "$target" ]; then
            	echo 'app-swap: refused: Applications or k3sm.app in it is a symlink or not a folder'
            	exit \#(AppSwapRootExit.targetRefused)
            fi

            """#
    }()
}
