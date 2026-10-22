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

/// BundledRollExit names the exit statuses the version set's root step
/// chooses itself, beside the copy-out's (`CopyOutExit`, 64 to 77) and the
/// installed CLI's checks (`LifecycleExit.refusedBinary` 100,
/// `LifecycleExit.signatureRejected` 101). Any other non-zero status is the
/// installed CLI's own (`k3sm update apply`: 1 refused or failed, 2 usage).
public enum BundledRollExit {
    /// The verified copy's `payload.release` is missing, not a regular file,
    /// a symlink, larger than `BundledRollPlan.maxRecordBytes`, holds a
    /// carriage return, or does not hold each key exactly once.
    public static let recordRefused: Int32 = 102
    /// The record's tag, the bundle's `K3smPayloadTag` and the tag the app
    /// passed are not the same text, or that text is not a release tag in
    /// the strict grammar.
    public static let tagMismatch: Int32 = 103
    /// The record's `tarball_sha256` is not 64 lowercase hex digits.
    public static let digestRefused: Int32 = 104
    /// A command of the record check itself failed (`stat`, `grep` or `sed`
    /// reading the record), so its statuses never pass for the CLI's own 1
    /// and 2.
    public static let recordUnreadable: Int32 = 105
}

/// BundledRollPlan is the version set's root step as data: the running app
/// bundle to copy, the release the user confirmed (exactly the app's own
/// `K3smPayloadTag`), and the team whose Developer ID signature both the
/// copy and the installed CLI must carry. The bundle path passes the
/// copy-out's checks (`CopyOutPlan.checkBundlePath`).
public struct BundledRollPlan: Hashable, Sendable {
    /// The sealed record of the bundled release, relative to the bundle root.
    public static let recordPath = "Contents/Resources/payload.release"
    /// The bundle's Info.plist, relative to the bundle root.
    public static let infoPlistPath = "Contents/Info.plist"
    /// The largest record read; the real one is under 300 bytes.
    public static let maxRecordBytes = 1024
    /// The record's keys, each of which must appear exactly once.
    public static let recordKeys = ["tag", "tarball_sha256", "payload_manifest_sha256"]
    /// The `mktemp -d` template of this step's stage under the copy-out's
    /// staging root. It carries no text from the app.
    public static let stagingTemplate = CopyOutPlan.stagingRoot + "/bundled-roll.XXXXXXXX"
    /// The strict release tag grammar, as the shell checks it
    /// (`BundledRollSupport.isReleaseTag` is the same rule in Swift).
    public static let tagPattern = #"^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?$"#
    /// The archive digest grammar.
    public static let digestPattern = "^[0-9a-f]{64}$"

    public let bundlePath: String
    public let release: ReleaseTag
    public let teamID: TeamID

    /// PlanError says why a plan was refused before any script was rendered.
    public enum PlanError: Error, Equatable, Sendable {
        case bundlePath(CopyOutPlan.PlanError)
        /// The tag is not a release tag in the strict grammar.
        case tagNotARelease
    }

    public init(bundlePath: String, release: ReleaseTag, teamID: TeamID) throws(PlanError) {
        do {
            try CopyOutPlan.checkBundlePath(bundlePath)
        } catch {
            throw .bundlePath(error)
        }
        guard BundledRollSupport.isReleaseTag(release.value) else { throw .tagNotARelease }
        self.bundlePath = bundlePath
        self.release = release
        self.teamID = teamID
    }

    /// The code requirement the staged copy must satisfy: the Developer ID
    /// requirement for the team and the app's own code signing identifier.
    public var designatedRequirement: String {
        DesignatedRequirement.developerID(teamID: teamID) + " and identifier \"\(AppUpdateTrust.bundleIdentifier)\""
    }
}

/// BundledRollScriptBuilder renders the version set's root step: the roll of
/// every node to the release this app carries, bound to the archive digest
/// its signed bundle records. In order, the script
///
///  1. copies the running bundle into a fresh root-owned stage and verifies
///     the copy against the Developer ID requirement and the app's identifier
///     (the copy-out's own text, `RootScriptBuilder.stagedCopy`), so nothing
///     after it reads the bundle in /Applications, which an admin user can
///     rewrite;
///  2. reads `payload.release` from the verified copy (a regular file, not a
///     symlink, at most `maxRecordBytes`, no carriage return, each key
///     exactly once);
///  3. reads `K3smPayloadTag` from the verified copy's Info.plist;
///  4. refuses unless the record's tag, `K3smPayloadTag` and the tag the app
///     passed are the same text in the strict release grammar, and the
///     record's `tarball_sha256` (the archive digest the CLI's pin compares
///     with the release's checksums file) is 64 lowercase hex digits;
///  5. checks the installed CLI as every lifecycle verb does
///     (`InstalledCLIPreamble`);
///  6. runs `k3sm update apply --yes --version <tag> --pin-sha256 "$digest"`
///     (`arguments(tag:digestVariable:)`), the digest passed as a quoted
///     shell variable, never as text in the script.
///
/// The script reads no stdin and keeps no output; it holds the copy-out
/// lock, and its stage is removed on every exit path. The CLI's standard
/// error goes back to the app (the classification reads it); everything
/// else is in the copy-out log.
public enum BundledRollScriptBuilder {
    /// The administrator prompt. Fixed text.
    public static let prompt = "k3sm wants to update every node of this cluster to the k3sm release this app carries."

    /// The shell variable the script reads the digest into.
    public static let digestVariable = "digest"

    /// ScriptWord is one word of the CLI line: fixed text, single-quoted, or
    /// a shell variable the script set itself, double-quoted.
    public enum ScriptWord: Hashable, Sendable {
        case literal(String)
        case variable(String)

        /// The word as the script writes it.
        public var rendered: String {
            switch self {
            case .literal(let s): return ShellQuote.quote(s)
            case .variable(let name): return "\"$\(name)\""
            }
        }
    }

    /// The argv after the CLI path: the one place the app writes
    /// `--pin-sha256`. Every flag is fixed text; the tag is the release the
    /// user confirmed; the digest is the variable `digestVariable` names.
    public static func arguments(tag: ReleaseTag, digestVariable: String) -> [ScriptWord] {
        [.literal("update"), .literal("apply"), .literal("--yes"),
         .literal("--version"), .literal(tag.value),
         .literal("--pin-sha256"), .variable(digestVariable)]
    }

    /// Renders the script for the installed CLI at `K3smCLI.path`.
    public static func render(plan: BundledRollPlan) -> RootScript {
        render(plan: plan, cliPath: K3smCLI.path)
    }

    /// Renders the script for a CLI at `cliPath`. Only the tests pass
    /// another path.
    static func render(plan: BundledRollPlan, cliPath: String) -> RootScript {
        let line = (["\"$k3sm\""] + arguments(tag: plan.release, digestVariable: digestVariable).map(\.rendered))
            .joined(separator: " ")
        let text = "exec 4>&2\n"
            + RootScriptBuilder.stagedCopy(bundlePath: plan.bundlePath, stagingTemplate: BundledRollPlan.stagingTemplate,
                                           designatedRequirement: plan.designatedRequirement)
            + "bundle=\(RootScriptBuilder.stagedBundle)\n"
            + "tag=\(ShellQuote.quote(plan.release.value))\n"
            + recordCheck
            + InstalledCLIPreamble.render(teamID: plan.teamID, cliPath: cliPath)
            + "echo 'bundled-roll: running k3sm update apply'\n"
            + line + " 2>&4\n"
        return RootScriptBuilder.stagedStep(text: text, prompt: prompt, readsInput: false)
    }

    /// The record and tag checks over the verified copy at `$bundle`,
    /// against the tag the app passed, `$tag`. It leaves the archive digest
    /// in `$digest`, and exits `BundledRollExit` codes on a refusal. The
    /// tests run it alone on fixtures, so it uses nothing the copy sets up
    /// but `$bundle` and `$tag`.
    static let recordCheck: String = {
        let q = ShellQuote.quote
        let keyChecks = BundledRollPlan.recordKeys.map(q).joined(separator: " ")
        return #"""
            echo 'bundled-roll: reading the payload record'
            record="$bundle"/\#(q(BundledRollPlan.recordPath))
            nl='
            '
            cr=$(printf '\r')
            record_refused() {
            	echo "bundled-roll: refused: $1"
            	exit \#(BundledRollExit.recordRefused)
            }
            tag_refused() {
            	echo "bundled-roll: refused: $1"
            	exit \#(BundledRollExit.tagMismatch)
            }
            check_failed() {
            	echo "bundled-roll: refused: $1"
            	exit \#(BundledRollExit.recordUnreadable)
            }
            if [ -L "$record" ] || [ ! -f "$record" ]; then record_refused 'the payload record is missing, a symlink or not a regular file'; fi
            size=$(/usr/bin/stat -f %z "$record") || check_failed 'the payload record could not be measured'
            case "$size" in ''|*[!0-9]*) check_failed 'the payload record could not be measured' ;; esac
            if [ "$size" -gt \#(BundledRollPlan.maxRecordBytes) ]; then record_refused 'the payload record is larger than \#(BundledRollPlan.maxRecordBytes) bytes'; fi
            if /usr/bin/grep -q "$cr" "$record"; then
            	record_refused 'the payload record holds a carriage return'
            else
            	st=$?
            	if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi
            fi
            for key in \#(keyChecks); do
            	n=$(/usr/bin/grep -c "^$key=" "$record") || { st=$?; if [ "$st" -ne 1 ]; then check_failed 'the payload record could not be read'; fi; }
            	if [ "$n" != 1 ]; then record_refused "the payload record holds $n $key lines, not exactly one"; fi
            done
            record_tag=$(/usr/bin/sed -n 's/^tag=//p' "$record") || check_failed 'the payload record could not be read'
            digest=$(/usr/bin/sed -n 's/^tarball_sha256=//p' "$record") || check_failed 'the payload record could not be read'
            plist_tag=$(/usr/libexec/PlistBuddy -c 'Print :\#(AppVersion.payloadTagKey)' "$bundle"/\#(q(BundledRollPlan.infoPlistPath))) || plist_tag=
            case "$tag" in *"$nl"*|*"$cr"*) tag_refused 'the release tag holds a line break' ;; esac
            if ! printf '%s\n' "$tag" | /usr/bin/grep -Eq \#(q(BundledRollPlan.tagPattern)); then tag_refused 'the release tag is not a release tag'; fi
            if [ "$record_tag" != "$tag" ]; then tag_refused 'the payload record names another release'; fi
            if [ "$plist_tag" != "$tag" ]; then tag_refused 'the bundle names another release in K3smPayloadTag'; fi
            case "$digest" in *"$nl"*|*"$cr"*) digest_ok=no ;; *) digest_ok=yes ;; esac
            if [ "$digest_ok" != yes ] || ! printf '%s\n' "$digest" | /usr/bin/grep -Eq \#(q(BundledRollPlan.digestPattern)); then
            	echo 'bundled-roll: refused: the payload record tarball_sha256 is not 64 lowercase hex digits'
            	exit \#(BundledRollExit.digestRefused)
            fi
            echo 'bundled-roll: the payload record matches the release'

            """#
    }()
}

extension UpdatePrecondition {
    /// The version set's check, read live before and after the question:
    /// this Mac is the server with no roll under way; `tag` is a release tag
    /// in the strict grammar (the caller passes the app's own
    /// `K3smPayloadTag`); the k3sm the server reports (`StatusReport.release`)
    /// is a tagged release below it, with the release pin, in the same major
    /// release and at most one minor behind; the server's own Node runs a
    /// release whose controller enforces the pin; the node list was read and
    /// every node in it is Ready; and, sorted against `tag` as the
    /// controller would (`ClusterCatchUp.decide(report:target:)`), the
    /// server's own Node is known, no node is ahead, and at least one moves.
    public static func bundled(tag: String, live: StatusReport?, nodes: [ClusterNode]?) -> CatchUpRelease {
        let unchanged = " Nothing was changed."
        guard let pinned = ReleaseTag(tag), BundledRollSupport.isReleaseTag(tag), let set = SemanticVersion(tag) else {
            return .refused(UpdateDriver.invalidTagText)
        }
        guard let live else {
            return .refused("k3sm could not read the status of this Mac just now, so it did not start the update.")
        }
        if UpdateOffer.rowRolling(in: live) {
            return .refused("An update is already rolling. The window shows its progress.")
        }
        guard NodeRole.detect(in: live) == .server else {
            return .refused("This Mac no longer reports itself as the server, so it did not start the update." + unchanged)
        }
        guard let installedTag = live.release?.tag, let installed = SemanticVersion(installedTag) else {
            return .refused(UpdateBlock.installedUnknownText + unchanged)
        }
        guard installed < set else {
            return .refused("The server already runs k3sm \(StatusDisplay.clip(installedTag)), not older than \(StatusDisplay.clip(tag)), so there is nothing to update." + unchanged)
        }
        guard BundledRollSupport.hasPin(tag: installedTag) else {
            return .refused(UpdateBlock.bundledServerCLITooOld(installed: installed, tag: tag).sentence + unchanged)
        }
        guard BundledRollSupport.skewAllowed(installed: installed, set: set) else {
            return .refused(UpdateBlock.bundledSkewTooWide(installed: installed, set: set).sentence + unchanged)
        }
        guard let running = ClusterCatchUp.serverRunning(report: live) else {
            return .refused(UpdateBlock.serverNodeUnknownText + unchanged)
        }
        guard BundledRollSupport.hasPin(tag: running) else {
            return .refused(UpdateBlock.bundledControllerTooOld(tag: tag).sentence + unchanged)
        }
        guard let nodes else { return .refused(UpdateBlock.bundledNodesUnknownText + unchanged) }
        let notReady = nodes.filter { $0.ready != true }.map(\.name).sorted()
        guard notReady.isEmpty else { return .refused(UpdateBlock.bundledNodeNotReady(notReady).sentence + unchanged) }
        guard let roll = ClusterCatchUp.decide(report: live, target: tag) else {
            return .refused("k3sm could not list the cluster's other nodes just now, so it did not start the update." + unchanged)
        }
        guard roll.serverKnown, let server = roll.server else { return .refused(UpdateBlock.serverNodeUnknownText + unchanged) }
        if !roll.ahead.isEmpty {
            return .refused(UpdateBlock.nodesAhead(tag: tag, nodes: roll.ahead).sentence + unchanged)
        }
        guard !roll.moves.isEmpty else {
            return .refused("Every node runs k3sm \(StatusDisplay.clip(tag)) now, so there is nothing to update." + unchanged)
        }
        return .proceed(pinned, nodes: roll.moves, server: server)
    }
}

extension LifecycleConfirmation {
    /// The version set's question: the release this app carries, the nodes
    /// that move (workers first, this server last), that the roll is bound
    /// to the digest the app's signed bundle records, and the datastore
    /// checks a server update shows (`UpdatePolicy.serverChecks`). It offers
    /// no option and no downgrade.
    public init(bundled tag: String, nodes: [String], server: String) {
        verb = .updateApply
        update = .defaults
        offersDowngrade = false
        cancelIsDefault = false
        cancelTitle = "Cancel"
        warning = nil
        let release = StatusDisplay.clip(tag)
        title = "Update the cluster to k3sm \(release)?"
        let others = nodes.filter { $0 != server }
        let order: String
        switch (others.isEmpty, nodes.contains(server)) {
        case (false, true):
            order = "\(UpdatePath.names(others)) first, one node at a time, then this server, \(StatusDisplay.clip(server)), last."
        case (true, true):
            order = "Only this server, \(StatusDisplay.clip(server)), moves; it restarts."
        default:
            order = "\(UpdatePath.names(others)) move, one node at a time; this server's node already runs it."
        }
        message = "k3sm moves the cluster to \(release), the release this app carries, and binds the update to the digest "
            + "this app's signed bundle records, so the nodes install exactly those bytes. " + order + " "
            + "Pods on each node that moves restart as it updates. "
            + "The window shows the progress, and the update can be cancelled from there.\n\n"
            + UpdatePolicy.serverChecks.joined(separator: " ")
    }
}

/// BundledRollOutcome turns the version set's own refusals into the
/// sentence the app shows. Each one ran nothing past its check.
public enum BundledRollOutcome {
    /// The sentence for a status the script or the copy chose itself; nil
    /// for any other status (the installed CLI's, read by
    /// `UpdateDriver.classify`).
    public static func text(exitStatus: Int32) -> String? {
        switch exitStatus {
        case CopyOutExit.refusedPath:
            return "A path the update uses as root is a symlink, so nothing was run. Nothing was changed."
        case CopyOutExit.refusedTree:
            return "The copy of this app held an unsafe file, so nothing was run. Nothing was changed."
        case CopyOutExit.busy:
            return "Another install or update from the app is running. Nothing was changed."
        case CopyOutExit.signatureRejected:
            return "This app is not signed by the k3sm Developer ID, so it cannot bind an update to its release. Nothing was changed."
        case BundledRollExit.recordRefused:
            return "This app's record of its k3sm release is missing or malformed, so nothing was run. Download k3sm.app again. Nothing was changed."
        case BundledRollExit.tagMismatch:
            return "This app's record of its k3sm release does not name the release offered, so nothing was run. Nothing was changed."
        case BundledRollExit.digestRefused:
            return "This app's record of its k3sm release has no valid digest, so nothing was run. Download k3sm.app again. Nothing was changed."
        case BundledRollExit.recordUnreadable:
            return "k3sm could not read this app's record of its k3sm release as root, so nothing was run. Nothing was changed."
        default:
            return nil
        }
    }

    /// The sentence when the installed CLI did not accept the pinned apply
    /// (exit 2): a CLI without `--pin-sha256`, or a digest it refused.
    public static func usage(_ cliText: String) -> String {
        "The installed k3sm did not accept an update bound to this app's release, so nothing was started."
            + (cliText.isEmpty ? "" : " " + cliText)
    }
}

/// BundledRollDriver runs the version set's roll from a click to its
/// outcome. It refuses a tag that is not a release tag in the strict
/// grammar before anything is read; reads the status and the node list and
/// checks them (`UpdatePrecondition.bundled`); asks, naming the release, the
/// nodes that move and the datastore checks; reads and checks again and
/// refuses when the nodes that would move changed; runs the checked root
/// step (`BundledRollScriptBuilder`) behind one administrator prompt; and,
/// when the roll started, watches the Update, unprivileged, until the
/// controller resolves the release. A resolve that is not `ResolvedPinned`
/// means the controller did not enforce the pin, and the driver cancels the
/// roll before a node starts: unprivileged through the trust-checked CLI
/// first, then through the root cancel when that did not run, failed, or
/// was not seen to take effect.
///
/// The watch and the unprivileged cancel run with the user's own cluster
/// credentials, which need not name the cluster the root step updated. So
/// every claim the driver makes rests on what it read of the Update the
/// root step created (`UpdateIdentity`): "bound" only on a `ResolvedPinned`
/// reading of it, "cancelled" only on a Cancelled reading of it after a
/// cancel. An Update that finished as Succeeded or Failed first has its own
/// sentence, because nodes may have started. Anything else is reported as
/// unconfirmed, with the Terminal command that checks the server itself.
///
/// Residual: name plus release tag can match an Update on a different
/// cluster that the user's kubeconfig reaches, so "bound" and "cancelled"
/// are status messages about whichever cluster was read, not a trust claim.
/// The control is the server-side `k3sm.io/release-pin-required` annotation
/// (k3sm#806), whose removal needs cluster-admin.
public struct BundledRollDriver: Sendable {
    /// The Resolved condition, and the reasons the controller gives it
    /// (`pkg/updatectl` `ConditionResolved`, `ReasonResolvedPinned`,
    /// `ReasonReleasePinMismatch`).
    public static let resolvedCondition = "Resolved"
    public static let resolvedPinnedReason = "ResolvedPinned"
    public static let pinMismatchReason = "ReleasePinMismatch"
    /// How often and how many times the Update is read after the start.
    public static let watchInterval: Duration = .seconds(3)
    public static let watchReads = 40

    /// The Update the root step created. `k3sm update apply` keeps one
    /// Update, named `current` (`updatesv1alpha1.UpdateName`), and
    /// `k3sm update status -o json` gives its name and version but no uid, so
    /// these two, with the pre-run reading set aside, are the identity. They
    /// can match an Update on another cluster the user's kubeconfig reaches,
    /// so a match is a status message, not a trust claim; the control is the
    /// server's `k3sm.io/release-pin-required` annotation (k3sm#806), whose
    /// removal needs cluster-admin.
    public struct UpdateIdentity: Equatable, Sendable {
        /// `updatesv1alpha1.UpdateName`.
        public static let createdName = "current"
        public let name: String
        public let version: String

        public init(tag: String) {
            name = Self.createdName
            version = tag
        }

        /// Whether `status` is a reading of this Update.
        public func matches(_ status: UpdateStatus) -> Bool {
            status.name == name && status.version == version
        }
    }

    /// How many times the Update is read after a cancel before the cancel
    /// counts as not confirmed.
    public static let cancelConfirmReads = 10

    public static let unboundCancelled =
        "The update was not bound to this app's release, so k3sm cancelled it before any node started."
    public static let unboundCancelUnconfirmed =
        "The update was not bound to this app's release. k3sm asked to cancel it but could not confirm that it stopped. "
        + "Run `sudo k3sm update status` in Terminal to check, and `sudo k3sm update cancel` to stop it."
    public static let unboundNotCancelled =
        "The update was not bound to this app's release, and k3sm could not cancel it. Cancel it from the window, or run `sudo k3sm update cancel` in Terminal."
    public static let pinMismatch =
        "The release on the release host does not match the digest this app records, so the server refused the update before touching any node."
    public static let bindingUnconfirmed =
        "The update has started. The server had not yet resolved the release when k3sm stopped watching; it refuses any release that does not match this app's digest."
    public static let endedUnresolved =
        "The update ended before the server resolved its release. The window shows why."
    public static let bound =
        "The update has started, bound to this app's release. Each node updates in turn, the server last."

    let teamID: TeamID
    let bundlePath: String
    let readStatus: @Sendable () async -> StatusReport?
    let readNodes: @Sendable () async -> [ClusterNode]?
    let confirm: @MainActor @Sendable (LifecycleConfirmation) async -> Bool
    let runner: any PrivilegedRunner
    let readUpdate: @Sendable () async -> UpdateStatus?
    let cancelUnprivileged: @Sendable () async -> Bool
    let sleep: @Sendable (Duration) async -> Void

    /// `cancelUnprivileged` runs `k3sm update cancel` through the
    /// trust-checked CLI as the user and returns true only when it ran and
    /// exited 0. `sleep` paces the watch; the tests pass one that returns at once.
    public init(
        teamID: TeamID,
        bundlePath: String,
        readStatus: @escaping @Sendable () async -> StatusReport?,
        readNodes: @escaping @Sendable () async -> [ClusterNode]?,
        confirm: @escaping @MainActor @Sendable (LifecycleConfirmation) async -> Bool,
        runner: any PrivilegedRunner,
        readUpdate: @escaping @Sendable () async -> UpdateStatus?,
        cancelUnprivileged: @escaping @Sendable () async -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.teamID = teamID
        self.bundlePath = bundlePath
        self.readStatus = readStatus
        self.readNodes = readNodes
        self.confirm = confirm
        self.runner = runner
        self.readUpdate = readUpdate
        self.cancelUnprivileged = cancelUnprivileged
        self.sleep = sleep
    }

    /// The refusal for a bundle path the copy-out's checks refuse.
    public static let bundlePathText = "k3sm cannot use this app's own location for the update. Move k3sm.app to Applications. Nothing was changed."

    /// Starts the roll to `tag`, the app's own payload tag.
    public func apply(tag: String) async -> UpdateDriver.Result {
        guard let release = ReleaseTag(tag), BundledRollSupport.isReleaseTag(tag) else {
            return .refused(UpdateDriver.invalidTagText)
        }
        let plan: BundledRollPlan
        do {
            plan = try BundledRollPlan(bundlePath: bundlePath, release: release, teamID: teamID)
        } catch {
            return .refused(Self.bundlePathText)
        }
        let asked: [String]
        let server: String
        switch UpdatePrecondition.bundled(tag: tag, live: await readStatus(), nodes: await readNodes()) {
        case .proceed(_, let nodes, let name):
            asked = nodes
            server = name
        case .refused(let why): return .refused(why)
        }
        guard await confirm(LifecycleConfirmation(bundled: tag, nodes: asked, server: server)) else { return .declined }
        switch UpdatePrecondition.bundled(tag: tag, live: await readStatus(), nodes: await readNodes()) {
        case .proceed(_, let nodes, let name) where nodes == asked && name == server: break
        case .proceed:
            return .refused("The nodes the update would move changed while the question was open. Nothing was changed.")
        case .refused(let why): return .refused(why)
        }
        let before = await readUpdate()
        let run = await runner.runAsRootReportingError(BundledRollScriptBuilder.render(plan: plan), input: nil)
        let result = Self.classify(run)
        guard case .ran(.started, let outcome, _) = result else { return result }
        return .ran(.started, outcome, await watch(tag: tag, before: before))
    }

    /// Reads one finished root step: the script's own refusals by their
    /// sentence, the CLI's usage refusal (an older CLI or a refused digest),
    /// and everything else as the managed apply reads it.
    public static func classify(_ run: PrivilegedRun) -> UpdateDriver.Result {
        if case .failed(let status) = run.outcome {
            if let text = BundledRollOutcome.text(exitStatus: status) {
                return .ran(.notStarted, run.outcome, text)
            }
            if status == LifecycleExit.usage {
                return .ran(.notStarted, run.outcome, BundledRollOutcome.usage(run.errorOutput.map(StatusDisplay.errorText) ?? ""))
            }
        }
        return UpdateDriver.classify(run, verb: .updateApply)
    }

    /// Whether `status` is a reading of the Update the root step created:
    /// the identity matches, and it is not the finished Update read before
    /// the run, which the apply replaced.
    static func created(_ status: UpdateStatus, identity: UpdateIdentity, before: UpdateStatus?) -> Bool {
        guard identity.matches(status) else { return false }
        if let before, before.finished, status == before { return false }
        return true
    }

    /// Watches the Update to `tag` the root step created until the
    /// controller resolves its release, and returns the sentence to show.
    /// `before` is the reading taken just before the root step. A reading
    /// of any other Update, or no reading, proves nothing and is skipped. An
    /// unpinned resolve is cancelled.
    func watch(tag: String, before: UpdateStatus?) async -> String {
        let identity = UpdateIdentity(tag: tag)
        for read in 0..<Self.watchReads {
            if read > 0 { await sleep(Self.watchInterval) }
            guard let status = await readUpdate(), Self.created(status, identity: identity, before: before) else { continue }
            if let resolved = status.conditions.first(where: { $0.type == Self.resolvedCondition }) {
                if resolved.status == "True" {
                    if resolved.reason == Self.resolvedPinnedReason { return Self.bound }
                    return await cancelUnbound(identity: identity, before: before)
                }
                if resolved.reason == Self.pinMismatchReason { return Self.pinMismatch }
            }
            if status.finished { return Self.endedUnresolved }
        }
        return Self.bindingUnconfirmed
    }

    /// Cancels a roll the controller resolved without the pin: as the user
    /// first; then as root when that did not run, failed, or was not seen to
    /// take effect. "Cancelled" is said only after a reading of the same
    /// Update shows it Cancelled or finished.
    func cancelUnbound(identity: UpdateIdentity, before: UpdateStatus?) async -> String {
        if await cancelUnprivileged() {
            let seen = await cancelSeen(identity: identity, before: before)
            if let sentence = seen.sentence { return sentence }
        }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.render(.updateCancel, teamID: teamID), input: nil)
        guard run.outcome == .succeeded else { return Self.unboundNotCancelled }
        return await cancelSeen(identity: identity, before: before).sentence ?? Self.unboundCancelUnconfirmed
    }

    /// What a re-read of the created Update showed after a cancel.
    enum CancelSeen: Equatable {
        /// Phase Cancelled: nothing more ran.
        case cancelled
        /// It finished some other way (Succeeded, Failed) before the cancel
        /// landed, so nodes may have started. Never reported as cancelled.
        case endedBeforeCancel(UpdatePhase)
        /// No reading of it showed an end.
        case unseen

        /// The sentence for this reading; nil when nothing was confirmed.
        var sentence: String? {
            switch self {
            case .cancelled: return BundledRollDriver.unboundCancelled
            case .endedBeforeCancel(let phase): return BundledRollDriver.endedBeforeCancel(phase)
            case .unseen: return nil
            }
        }
    }

    /// The sentence for an Update that finished as `phase` before the cancel
    /// landed. The phase word is the CLI's own and is shown cleaned.
    static func endedBeforeCancel(_ phase: UpdatePhase) -> String {
        let how = phase == .succeeded ? "succeeded" : (phase == .failed ? "failed" : "ended as \(StatusDisplay.clip(phase.word))")
        return "The update was not bound to this app's release, and it \(how) before k3sm's cancel took effect, so nodes may have been updated. "
            + "Run `sudo k3sm update status` in Terminal to see what it did."
    }

    /// Whether a reading of the created Update shows it Cancelled, or
    /// finished another way, within `cancelConfirmReads` reads.
    func cancelSeen(identity: UpdateIdentity, before: UpdateStatus?) async -> CancelSeen {
        for read in 0..<Self.cancelConfirmReads {
            if read > 0 { await sleep(Self.watchInterval) }
            guard let status = await readUpdate(), Self.created(status, identity: identity, before: before) else { continue }
            if status.phase == .cancelled { return .cancelled }
            if status.finished { return .endedBeforeCancel(status.phase) }
        }
        return .unseen
    }
}
