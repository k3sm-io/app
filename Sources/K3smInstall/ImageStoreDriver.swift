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

/// ImageStoreDriver runs the Images tab's writes, Untag, Prune and Pull,
/// through the checked root step (`LifecycleScriptBuilder.renderImage`), on
/// this Mac's node only (`ImageStoreScope`). Untag asks first, naming the
/// image and the node; Pull takes its reference only as an `ImageRef` and
/// asks first, naming the registry the root step contacts; Prune
/// is two steps, its dry run (`previewPrune`), whose output is parsed and
/// shown, then, when the user confirms that list, `prune` with `--force`.
public struct ImageStoreDriver: Sendable {
    /// How one write ended.
    public enum Result: Equatable, Sendable {
        /// The user answered no; nothing ran.
        case declined
        /// The app refused before any prompt; nothing ran.
        case refused(String)
        /// The dry run read: what a prune would delete.
        case preview(ImagePrunePreview)
        /// The root step ran (or was cancelled at its prompt), with its line.
        case ran(PrivilegedOutcome, String)
    }

    let teamID: TeamID
    let runner: any PrivilegedRunner
    let confirm: @MainActor @Sendable (_ question: Question) async -> Bool

    /// Question is what is asked before a write: its title, message and the
    /// button that runs it.
    public struct Question: Equatable, Sendable {
        public let title: String
        public let message: String
        public let verbTitle: String
    }

    public init(teamID: TeamID, runner: any PrivilegedRunner,
                confirm: @escaping @MainActor @Sendable (_ question: Question) async -> Bool) {
        self.teamID = teamID
        self.runner = runner
        self.confirm = confirm
    }

    /// Why the tab's writes are disabled now, or nil when they may run:
    /// the root step's availability first, then this Mac's node, then a
    /// write already running.
    public static func disabledReason(scope: ImageStoreScope, availability: PrivilegedAvailability, busy: Bool) -> String? {
        if case .disabled(let reason) = availability { return reason }
        if scope.node == nil { return ImageStoreScope.unknownNodeText }
        if busy { return "Another change is running." }
        return nil
    }

    /// The refusal when the tag is not one this Mac's node holds for the image.
    public static func notOnThisMac(node: String) -> String {
        "That name is not a tag of this image on node \(node), this Mac, so nothing was changed."
    }

    /// Untags `reference` on this Mac's node, after asking. The reference
    /// must be one of the image's tags there (`ImageStoreOffer`).
    public func untag(_ reference: ImageRef, of image: NodeImage, scope: ImageStoreScope) async -> Result {
        guard let node = scope.node else { return .refused(ImageStoreScope.unknownNodeText) }
        guard ImageStoreOffer.decide(image, scope: scope).untag.contains(reference) else {
            return .refused(Self.notOnThisMac(node: node))
        }
        let question = ImageStoreText.untagQuestion(reference, node: node)
        guard await confirm(Question(title: question.title, message: question.message, verbTitle: "Untag")) else { return .declined }
        return await run(.untag(reference), node: node)
    }

    /// Pulls the reference typed in the Pull field, trimmed, only once it
    /// passes `ImageRef`, after asking (naming the node and the registry).
    public func pull(_ text: String, scope: ImageStoreScope) async -> Result {
        guard let node = scope.node else { return .refused(ImageStoreScope.unknownNodeText) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let problem = ImageRef.problem(trimmed) { return .refused(ImageStoreText.pullRefused(problem)) }
        guard let reference = ImageRef(trimmed) else { return .refused(ImageStoreText.pullRefused(.invalidCharacter)) }
        let question = ImageStoreText.pullQuestion(reference, node: node)
        guard await confirm(Question(title: question.title, message: question.message, verbTitle: "Pull")) else { return .declined }
        return await run(.pull(reference), node: node)
    }

    /// Runs the prune's dry run and reads what it would delete. Nothing is
    /// deleted by it; an output that does not read is refused, not guessed at.
    public func previewPrune(scope: ImageStoreScope) async -> Result {
        guard let node = scope.node else { return .refused(ImageStoreScope.unknownNodeText) }
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.renderImage(.pruneDryRun, teamID: teamID), input: nil)
        guard run.outcome == .succeeded else { return Self.classify(run, verb: .pruneDryRun, node: node) }
        if run.outputTruncated { return .refused(ImageStoreText.previewTruncated) }
        switch ImagePrune.parse(run.output ?? "") {
        case .read(let preview): return .preview(preview)
        case let unreadable: return .refused(ImageStoreText.previewUnreadable(unreadable))
        }
    }

    /// Runs the prune with `--force`, after the user confirmed its preview.
    public func prune(scope: ImageStoreScope) async -> Result {
        guard let node = scope.node else { return .refused(ImageStoreScope.unknownNodeText) }
        return await run(.prune, node: node)
    }

    private func run(_ verb: LifecycleScriptBuilder.ImageVerb, node: String) async -> Result {
        let run = await runner.runAsRootReportingError(LifecycleScriptBuilder.renderImage(verb, teamID: teamID), input: nil)
        return Self.classify(run, verb: verb, node: node)
    }

    /// Reads one finished root step: the verb's line on success, the
    /// script's own refusals by their exit status, and any other failure
    /// with the CLI's error text, cleaned.
    public static func classify(_ run: PrivilegedRun, verb: LifecycleScriptBuilder.ImageVerb, node: String) -> Result {
        switch run.outcome {
        case .succeeded:
            switch verb {
            case .untag(let reference): return .ran(run.outcome, ImageStoreText.untagged(reference, node: node))
            case .pull(let reference): return .ran(run.outcome, ImageStoreText.pulled(reference, node: node, output: run.output))
            case .prune where run.outputTruncated: return .ran(run.outcome, ImageStoreText.prunedTruncated(node: node))
            case .prune: return .ran(run.outcome, ImageStoreText.pruned(output: run.output, node: node))
            case .pruneDryRun: return .ran(run.outcome, "")
            }
        case .cancelled:
            return .ran(run.outcome, "Cancelled. Nothing was changed.")
        case .couldNotStart:
            return .ran(run.outcome, "The administrator prompt could not be shown. Nothing was changed.")
        case .failed(LifecycleExit.refusedBinary):
            return .ran(run.outcome, "The installed k3sm at \(K3smCLI.path), or a folder above it, is not owned by root or is writable by others, so nothing was run.")
        case .failed(LifecycleExit.signatureRejected):
            return .ran(run.outcome, "The installed k3sm is not signed by the k3sm Developer ID, so nothing was run.")
        case .failed(let status):
            let cli = run.errorOutput.map(StatusDisplay.errorText) ?? ""
            if !cli.isEmpty { return .ran(run.outcome, "k3sm \(verb.command) failed: " + cli) }
            return .ran(run.outcome, "k3sm \(verb.command) failed with exit status \(status).")
        }
    }
}
