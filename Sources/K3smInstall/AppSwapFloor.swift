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

/// AppSwapRecovery is what the app offers when the administrator path for
/// the app swap (`AppSwapRootScriptBuilder`) ends in a refusal the user can
/// get past without it. Fixed text; nothing from the log or the cluster.
public struct AppSwapRecovery: Hashable, Sendable {
    /// The prompt's title.
    public let title: String
    /// What happened and what to do, one paragraph.
    public let message: String
    /// The button that opens `url`.
    public let actionTitle: String
    /// The page the button opens.
    public let url: String

    /// The offer for the administrator path's exit status, or nil when the
    /// status is a success or a refusal a reinstall does not get past.
    ///
    /// `targetUntrusted` (115) is the one dead end a user can reach on an
    /// ordinary Mac: a standard user, who cannot write `/Applications`, with
    /// a k3sm.app there that was copied in by an account (dragged from the
    /// disk image) rather than owned by root, is sent to the administrator
    /// path, which refuses a target that is not root's. The same status
    /// covers an installed copy older than root's floor record. In both the
    /// way forward is the release itself: the disk image's k3sm.app dragged
    /// to Applications is the update, with no swap.
    public static func forAdministratorExit(_ status: Int32) -> AppSwapRecovery? {
        guard status == AppSwapRootExit.targetUntrusted else { return nil }
        return reinstall
    }

    /// The offer for `targetUntrusted`.
    public static let reinstall = AppSwapRecovery(
        title: "Reinstall k3sm.app from the release",
        message: "k3sm could not update k3sm.app with administrator rights: the copy in Applications is not owned by the "
            + "system, or is older than the release this Mac last installed. Download k3sm.app from the release page "
            + "and drag it to Applications to install the update.",
        actionTitle: "Open the Release Page",
        url: GuidedSteps.releasesURL)
}

/// AppSwapFloor is root's floor record (`AppSwapRoot.floorRecord`) outside
/// the swap: the copy-out seeds it on an install and removes it on an
/// uninstall, and `resetCommand` removes it by hand.
///
/// The seed closes the swap's bootstrap window. With no record, the
/// administrator path's only floor is the installed bundle's own tag, so an
/// older genuine release raced into `/Applications` before the first swap
/// would pass the post-copy tag check. An install from the app at
/// `AppSwapRoot.target` writes that verified copy's release tag first.
public enum AppSwapFloor {
    /// The Terminal command that removes the record, for an administrator
    /// who must install an older release after uninstalling k3sm some other
    /// way (`sudo k3sm uninstall` leaves it).
    public static let resetCommand = "sudo rm -f " + AppSwapRoot.floorRecord

    /// The file the seed is written to in the stage before it is renamed
    /// into place. The stage sits under `CopyOutPlan.stagingRoot` in
    /// `/Library`, the record's volume, so the rename is one step, and the
    /// stage's removal on every exit path removes it after a failure.
    static let seedFileName = "app-floor"

    /// The seed at the shipped record path, owned by root.
    static let seed = seed(record: AppSwapRoot.floorRecord, owner: 0)

    /// The reset at the shipped record path.
    static let reset = reset(record: AppSwapRoot.floorRecord)

    /// Shell lines, run after the staged copy verified against the Developer
    /// ID (`$stage` set, `set -eu`, `umask 077`): when there is no record, not
    /// even a dangling symlink, and the verified copy's `K3smPayloadTag` is a
    /// release tag (`AppSwapRootScriptBuilder.tagRank`, the swap's grammar),
    /// write it with a newline to a file in the stage, give it to `owner`
    /// with mode 0600, and rename it to `record`. An existing record is never
    /// replaced or lowered: the swap raises it. An untagged copy writes
    /// nothing. A failing command ends the step under `set -e` before the
    /// staged k3sm runs; the record is then absent, as before, or whole.
    /// `record` and `owner` are the shipped path and root; tests render it
    /// over scratch paths.
    static func seed(record: String, owner: UInt32) -> String {
        let q = ShellQuote.quote
        let plist = RootScriptBuilder.stagedBundle + "/" + q("Contents/Info.plist")
        let file = "\"$stage\"/" + q(seedFileName)
        return AppSwapRootScriptBuilder.tagRank + #"""
            record=\#(q(record))
            if [ ! -e "$record" ] && [ ! -L "$record" ]; then
            	tag=$(/usr/bin/plutil -extract K3smPayloadTag raw -o - \#(plist) 2>/dev/null) || tag=
            	if tagrank > /dev/null; then
            		printf '%s\n' "$tag" > \#(file)
            		/usr/sbin/chown \#(owner) \#(file)
            		/bin/chmod 0600 \#(file)
            		/bin/mv -f \#(file) "$record"
            		echo "copy-out: recorded $tag as the app release floor"
            	fi
            fi

            """#
    }

    /// Shell lines, run after `k3sm uninstall` succeeded: remove the record,
    /// or a symlink in its place (never what it points at). Anything that is
    /// not removable by `rm -f`, a folder, fails the step under `set -e`.
    static func reset(record: String) -> String {
        #"""
            record=\#(ShellQuote.quote(record))
            if [ -e "$record" ] || [ -L "$record" ]; then
            	/bin/rm -f "$record"
            	echo 'copy-out: removed the app release floor record'
            fi

            """#
    }
}
