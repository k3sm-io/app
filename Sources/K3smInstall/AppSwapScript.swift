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

import K3smStatus

/// AppSwapPaths is every location the standard-user root path of the app
/// swap uses, each a compiled constant. The root step takes no path from
/// the app and reads none from the request file: the target is
/// `/Applications/k3sm.app`, root's own work directory is
/// `/Library/k3sm.app-update` (never under the copy-out's staging root,
/// whose every run sweeps it), and the staged bundle is found under the
/// console user's home, from that account's passwd entry, at the fixed
/// relative path `userStagedRelative`.
public enum AppSwapPaths {
    /// The Applications directory the root path updates in.
    public static let applications = "/Applications"
    /// The one bundle the root path replaces.
    public static let target = applications + "/k3sm.app"
    /// Root's own work directory, `root:wheel` 0700: the verified helper
    /// copy, the stage, the kept previous copy, the lock and the record.
    public static let workDirectory = "/Library/k3sm.app-update"
    /// The `mktemp` template of the helper copy in the work directory.
    public static let helperTemplate = "helper.XXXXXXXX"
    /// The prefix every helper copy's name carries.
    public static let helperPrefix = "helper."
    /// The stage in the work directory: the verified copy of the staged
    /// bundle, `stage/k3sm.app`.
    public static let stageName = "stage"
    /// The kept previous copy's directory in the work directory.
    public static let previousName = "previous"
    /// The lock file in the work directory.
    public static let lockName = "lock"
    /// The root-owned previous-copy record in the work directory.
    public static let recordName = "previous.json"
    /// The swap helper inside the app bundle.
    public static let bundledHelper = "Contents/Helpers/k3sm-app-update"
    /// Where the app stages the new bundle for the root path, relative to
    /// the account's home: inside the account's private 0700 update
    /// directory. The download that fills it uses this path too.
    public static let userStagedRelative = "Library/Application Support/io.k3sm.app/update/staged/k3sm.app"
    /// The device whose owner is the console user.
    public static let consoleDevice = "/dev/console"
}

/// AppSwapExit names the exit statuses of the app swap's root step: the
/// script's own refusals and the helper's `--root-swap` mode, which the
/// script execs. They sit beside the copy-out's (`CopyOutExit`, 64 to 77),
/// the lifecycle's (`LifecycleExit`, 1 to 4, 32 to 95, 100 and 101) and the
/// version set's (`BundledRollExit`, 102 to 105), so none collides.
///
/// The root step's 0 is `handedOff`: everything was verified and the
/// detached half, which does the swap after the app quits, has started. It
/// does not mean the swap stood. The detached half's own statuses
/// (`committed`, `committedWithoutRecord`, `leftUnconfirmed`, `rolledBack`,
/// `abandoned`, `refusedBySystem`) reach only the log; the relaunched app
/// learns the outcome from its journal.
public enum AppSwapExit: Int32, Sendable, CaseIterable {
    /// The root step verified everything and started the detached half.
    case handedOff = 0
    /// `/Applications`, the target, a directory inside it, the bundled
    /// helper or the work directory is a symlink, missing, or not the kind
    /// of file it must be.
    case refusedPath = 106
    /// The console user is not the account that asked.
    case consoleUser = 107
    /// The helper copy does not satisfy the helper requirement or does not
    /// carry the helper's identifier.
    case helperRejected = 108
    /// The helper's root mode refused its arguments, its account, its own
    /// location or its own signature.
    case refusedRequest = 109
    /// The staged bundle is missing, sits under a symlink or another
    /// account's directory, or its copy holds a symlink, a special file, a
    /// setuid or setgid file or a group- or other-writable entry.
    case stagedRefused = 110
    /// The staged copy or the installed bundle failed verification, or the
    /// staged tag is not strictly above the installed one.
    case verificationFailed = 111
    /// The work directory is not on the target's volume, or the volume
    /// cannot exchange two names in one step.
    case unsupportedVolume = 112
    /// Another root swap holds the lock.
    case busy = 113
    /// The detached half could not be started.
    case startFailed = 114
    /// The new app did not come up; the old one is back.
    case rolledBack = 115
    /// The swap stopped with nothing replaced, or could not be undone.
    case abandoned = 116
    /// macOS refused root's rename (`EPERM` or `EACCES`: App Management or
    /// System Integrity Protection); nothing was replaced.
    case refusedBySystem = 117
    /// The swap stood: the new app answered.
    case committed = 118
    /// The swap stood, but the root-owned previous record could not be
    /// written, so the kept copy cannot be gone back to.
    case committedWithoutRecord = 119
    /// The new bundle is in place and verified, but the user-side launch
    /// could not run (launchctl or sudo failed, or it timed out), so the new
    /// app was not confirmed; it was left in place, not rolled back.
    case leftUnconfirmed = 120
}

/// AppSwapAuthorization is the enabled result of
/// `PrivilegedAvailability.evaluateAppSwap`, and the only way to render the
/// app swap's root step. It is a distinct type with no public initializer,
/// so it cannot stand in for `PrivilegedAvailability.enabled`, which every
/// other root action requires: the app swap needs no admin-group account,
/// and that must not widen any other action.
public struct AppSwapAuthorization: Equatable, Sendable {
    /// The compiled Team ID the helper requirement is built from.
    public let teamID: TeamID

    init(teamID: TeamID) {
        self.teamID = teamID
    }
}

/// AppSwapAvailability is whether the app may offer to replace itself
/// through the administrator prompt, and if not, why.
public enum AppSwapAvailability: Equatable, Sendable {
    case enabled(AppSwapAuthorization)
    case disabled(reason: String)
}

/// AppSwapScriptBuilder renders the root step of the standard-user app
/// swap. The script takes no path from the app: its only values are three
/// integers (the account's uid, the app's pid and its start time in
/// microseconds), the release tag the app verified (strict grammar,
/// checked here and again by the helper), and the requirement built from
/// the compiled Team ID. It renders only with an `AppSwapAuthorization`. It:
///
/// 1. refuses a symlinked or missing `/Applications` or target;
/// 2. refuses unless the console user is the uid;
/// 3. makes the work directory `root:wheel` 0700, refusing a symlink;
/// 4. copies the installed bundle's helper (refusing a symlinked
///    `Contents`, `Helpers` or helper) into `helper.<random>` there, owned
///    by root, mode 0500;
/// 5. verifies the copy against `AppUpdateTrust.helperRequirement` and its
///    exact identifier;
/// 6. execs the copy with `--root-swap <uid> <pid> <start> <tag>`; the
///    helper refuses any staged bundle whose `K3smPayloadTag` is not exactly
///    that tag.
///
/// Root never runs a file a user can write: only that verified copy, in a
/// directory only root can enter.
public enum AppSwapScriptBuilder {
    /// The administrator prompt.
    public static let prompt = "k3sm wants to replace k3sm.app in Applications with the update you downloaded."

    /// The root mode's argument, which the helper also parses.
    public static let rootSwapArgument = "--root-swap"

    /// Renders the script for the authorized team, or nil for uid 0, a pid
    /// that names no process, or a tag outside the strict release grammar.
    public static func render(_ authorization: AppSwapAuthorization, uid: UInt32, appPid: Int32, appStart: UInt64,
                              expectedTag: String) -> RootScript? {
        render(helperRequirement: AppUpdateTrust.helperRequirement(teamID: authorization.teamID), uid: uid, appPid: appPid,
               appStart: appStart, expectedTag: expectedTag, layout: .production)
    }

    /// Layout is where the script looks. Only the tests pass another one,
    /// to prove the refusals against real scratch directories.
    struct Layout: Equatable {
        var applications: String
        var workDirectory: String
        var consoleDevice: String
        /// The `chown` owner of the work directory and the helper copy.
        var owner: String

        static let production = Layout(applications: AppSwapPaths.applications, workDirectory: AppSwapPaths.workDirectory,
                                       consoleDevice: AppSwapPaths.consoleDevice, owner: "root:wheel")

        var target: String { applications + "/k3sm.app" }
    }

    static func render(helperRequirement: String, uid: UInt32, appPid: Int32, appStart: UInt64, expectedTag: String,
                       layout: Layout) -> RootScript? {
        guard uid != 0, appPid > 0, BundledRollSupport.isReleaseTag(expectedTag) else { return nil }
        let q = ShellQuote.quote
        let text = #"""
            set -eu
            umask 077
            cd /
            apps=\#(q(layout.applications))
            target=\#(q(layout.target))
            work=\#(q(layout.workDirectory))
            console=\#(q(layout.consoleDevice))
            uid=\#(uid)
            helper=
            refuse() {
            	echo "app-swap: refused: $2" >&2
            	exit "$1"
            }
            cleanup() {
            	if [ -n "$helper" ]; then /bin/rm -f "$helper"; fi
            }
            trap cleanup EXIT
            trap 'exit 130' HUP INT TERM
            if [ -L "$apps" ] || [ ! -d "$apps" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'the Applications folder is a symlink or not a folder'; fi
            if [ -L "$target" ] || [ ! -d "$target" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'k3sm.app in Applications is a symlink or not a folder'; fi
            owner=$(/usr/bin/stat -f %u "$console") || refuse \#(AppSwapExit.consoleUser.rawValue) 'the console user could not be read'
            if [ "$owner" != "$uid" ]; then refuse \#(AppSwapExit.consoleUser.rawValue) 'the console user is not the account that asked'; fi
            if [ -L "$work" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'the work folder is a symlink'; fi
            if [ -e "$work" ] && [ ! -d "$work" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'the work folder is not a folder'; fi
            if [ ! -d "$work" ]; then /bin/mkdir -m 0700 "$work"; fi
            /usr/sbin/chown \#(q(layout.owner)) "$work"
            /bin/chmod 0700 "$work"
            if [ -L "$work" ] || [ ! -d "$work" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'the work folder is a symlink'; fi
            for p in "$target"/'Contents' "$target"/'Contents/Helpers'; do
            	if [ -L "$p" ] || [ ! -d "$p" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'a folder inside k3sm.app is a symlink or missing'; fi
            done
            src="$target"/\#(q(AppSwapPaths.bundledHelper))
            if [ -L "$src" ] || [ ! -f "$src" ]; then refuse \#(AppSwapExit.refusedPath.rawValue) 'the bundled helper is a symlink or not a regular file'; fi
            helper=$(/usr/bin/mktemp "$work"/\#(q(AppSwapPaths.helperTemplate)))
            /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$src" "$helper"
            if [ -L "$helper" ] || [ ! -f "$helper" ]; then refuse \#(AppSwapExit.helperRejected.rawValue) 'the helper copy is not a regular file'; fi
            /usr/sbin/chown \#(q(layout.owner)) "$helper"
            /bin/chmod 0500 "$helper"
            if ! /usr/bin/codesign --verify --strict \#(q("-R=" + helperRequirement)) "$helper"; then refuse \#(AppSwapExit.helperRejected.rawValue) 'the helper is not signed by the k3sm Developer ID'; fi
            ident=$(/usr/bin/codesign --display --verbose=1 "$helper" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p') || ident=
            if [ "$ident" != \#(q(AppUpdateTrust.helperIdentifier)) ]; then refuse \#(AppSwapExit.helperRejected.rawValue) 'the helper does not carry its identifier'; fi
            trap - EXIT
            exec "$helper" \#(rootSwapArgument) "$uid" \#(appPid) \#(appStart) \#(q(expectedTag))

            """#
        return RootScript(text: text, prompt: prompt, readsInput: false, usesStagingLock: false, result: .discarded)
    }
}

/// AppSwapOutcome turns the app swap's root step's own statuses into the
/// sentence the app shows. Each refusal replaced nothing.
public enum AppSwapOutcome {
    /// The sentence for `exitStatus`, nil for 0.
    public static func text(exitStatus: Int32) -> String? {
        guard let exit = AppSwapExit(rawValue: exitStatus) else {
            return "The update could not start as an administrator. k3sm.app was left as it was."
        }
        switch exit {
        case .handedOff:
            return nil
        case .committed:
            return "k3sm.app was updated."
        case .committedWithoutRecord:
            return "k3sm.app was updated, but the record of the previous version could not be kept, so it cannot be gone back to."
        case .leftUnconfirmed:
            return "k3sm.app was updated but could not be reopened. Open k3sm from Applications."
        case .refusedBySystem:
            return "macOS did not allow k3sm.app to be replaced, so nothing was changed. In System Settings, Privacy & Security, App Management, allow k3sm, then try again."
        case .refusedPath:
            return "k3sm.app or a folder the update uses is a symlink or missing, so nothing was replaced."
        case .consoleUser:
            return "The update must be confirmed by the person logged in at this Mac. Nothing was replaced."
        case .helperRejected:
            return "The installed k3sm.app is not signed by the k3sm Developer ID, so it cannot update itself. Download k3sm.app again."
        case .refusedRequest:
            return "The update helper refused to run as an administrator. Nothing was replaced."
        case .stagedRefused:
            return "The downloaded update is missing or unsafe, so nothing was replaced. Check for updates again."
        case .verificationFailed:
            return "The downloaded update is not a newer k3sm.app signed by the k3sm Developer ID. Nothing was replaced."
        case .unsupportedVolume:
            return "Move k3sm.app to Applications on the startup disk"
        case .busy:
            return "Another update of k3sm.app is running. Nothing was replaced."
        case .startFailed:
            return "The update could not start. Nothing was replaced."
        case .rolledBack:
            return "The updated k3sm.app did not start, so the previous version is back."
        case .abandoned:
            return "The update stopped before replacing k3sm.app. It was left as it was."
        }
    }
}
