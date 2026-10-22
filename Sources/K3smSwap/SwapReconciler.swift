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

import Darwin
import Foundation

/// ReconcileFacts is what the reconcile decision reads, all of it observed,
/// none of it taken from the journal's word.
public struct ReconcileFacts: Equatable, Sendable {
    /// Another process holds the journal lock: a helper is still at work.
    public var lockHeld: Bool
    /// The identity of what is at the target now; nil when nothing is.
    public var atTarget: FileIdentity?
    /// The running app's own `K3smPayloadTag`.
    public var runningTag: String?
    /// Whether the running app's signature check (`SelfCheck`) passes.
    public var runningSelfCheck: Bool
    /// Whether the original bundle is still present, in the previous root or
    /// where the swap left it, and verifies.
    public var outgoingVerifies: Bool

    public init(lockHeld: Bool, atTarget: FileIdentity?, runningTag: String?, runningSelfCheck: Bool, outgoingVerifies: Bool) {
        self.lockHeld = lockHeld
        self.atTarget = atTarget
        self.runningTag = runningTag
        self.runningSelfCheck = runningSelfCheck
        self.outgoingVerifies = outgoingVerifies
    }
}

/// ReconcileAction is what an app launch does about the journal.
public enum ReconcileAction: Equatable, Sendable, CaseIterable {
    /// No journal, a live helper, or nothing left to do.
    case nothing
    /// The new bundle is in place and running: finish the swap (keep the
    /// old one as the previous copy, remove the staging directory).
    case commit
    /// The swap did not happen or was undone: remove the incoming copy where
    /// it lies, and close the journal.
    case discard
    /// The new bundle is in place but did not come up: put the original back
    /// through the helper's `--go-back`.
    case swapBack
    /// Something else now sits at the target: touch nothing there, close the
    /// journal.
    case forget
    /// The new bundle is in place, is not the running app, and the original
    /// does not verify: there is nothing safe to do.
    case leave
}

/// ReconcileResult is what the app does next.
public enum ReconcileResult: Equatable, Sendable {
    /// Carry on launching.
    case carryOn
    /// The helper was started to swap back: quit now, before any UI.
    case quitForSwapBack
}

/// SwapReconciler runs at every app launch, before any UI, and finishes or
/// undoes a swap a killed helper, a logout or a reboot interrupted. It
/// decides from the identity actually at the target, because each journal
/// state is written before its act: `swapped` may mean no swap happened.
public struct SwapReconciler: Sendable {
    public let paths: SwapPaths
    /// Verifies the kept original before a swap back is offered.
    public let verifier: any BundleVerifier
    public let renamer: any Renamer
    /// The running app, which the go-back helper waits on.
    public let currentApp: ProcessIdentity?
    /// Starts the go-back: in the app, installs the helper copy and spawns it
    /// with `--go-back`. Returns whether it started.
    public let spawnGoBack: @Sendable () -> Bool

    public init(paths: SwapPaths, verifier: any BundleVerifier, renamer: any Renamer = SystemRenamer(),
                currentApp: ProcessIdentity?, spawnGoBack: @escaping @Sendable () -> Bool) {
        self.paths = paths
        self.verifier = verifier
        self.renamer = renamer
        self.currentApp = currentApp
        self.spawnGoBack = spawnGoBack
    }

    /// The pure decision.
    public static func decide(journal: SwapJournal?, facts: ReconcileFacts) -> ReconcileAction {
        guard let journal, !facts.lockHeld else { return .nothing }
        let holdsIncoming = facts.atTarget != nil && facts.atTarget == journal.incoming
        let holdsOriginal = facts.atTarget != nil && facts.atTarget == journal.original
        let runningIsIncoming = facts.runningSelfCheck && facts.runningTag == journal.request.expectedTag
        let unconfirmed: ReconcileAction = runningIsIncoming ? .commit : (facts.outgoingVerifies ? .swapBack : .leave)
        switch journal.state {
        case .committed:
            return .nothing
        case .rolledBack:
            // Written before the swap back: the new bundle may still be in
            // place, and then the swap back is finished.
            if holdsIncoming { return facts.outgoingVerifies ? .swapBack : (runningIsIncoming ? .commit : .leave) }
            return journal.incoming == nil ? .nothing : .discard
        case .staged, .verified, .swapped, .launched:
            if holdsIncoming { return unconfirmed }
            if holdsOriginal || journal.original == nil { return .discard }
            return .forget
        }
    }

    /// Reads the journal, gathers the facts, decides and acts.
    public func reconcile(runningTag: String?, runningSelfCheck: () -> Bool) -> ReconcileResult {
        let store = JournalStore(paths: paths)
        guard store.exists else { return .carryOn }
        guard let journal = try? store.read() else { return .carryOn }
        // The journal is this account's file; a name or tag outside its
        // grammar is never used, so nothing is decided from it.
        guard journal.namesAreValid, paths.allowedTargets.contains(journal.request.target) else {
            SwapLog.logger.error("reconcile: the journal fails its grammar; left as is")
            return .carryOn
        }
        let facts = gatherFacts(journal: journal, runningTag: runningTag, runningSelfCheck: runningSelfCheck)
        let action = Self.decide(journal: journal, facts: facts)
        SwapLog.reconcile(action)
        return perform(action, journal: journal)
    }

    /// The facts for `journal`, observed now.
    public func gatherFacts(journal: SwapJournal, runningTag: String?, runningSelfCheck: () -> Bool) -> ReconcileFacts {
        let store = JournalStore(paths: paths)
        let lockHeld = store.isLockHeld()
        let atTarget = FileIdentity.of(path: journal.request.target)
        var outgoingVerifies = false
        if journal.namesAreValid, let original = journal.original, let path = locate(original, journal: journal),
           let verified = try? verifier.verify(bundleAt: path, requireTag: false), verified.identity == original {
            outgoingVerifies = true
        }
        let selfCheck = journal.state.isTerminal && atTarget != journal.incoming ? false : runningSelfCheck()
        return ReconcileFacts(lockHeld: lockHeld, atTarget: atTarget, runningTag: runningTag, runningSelfCheck: selfCheck,
                              outgoingVerifies: outgoingVerifies)
    }

    /// Where an identity from the journal lies now: the previous copy's
    /// name, or the staging directory's bundle.
    func locate(_ identity: FileIdentity, journal: SwapJournal) -> String? {
        candidates(journal).first { FileIdentity.of(path: $0) == identity }
    }

    private func candidates(_ journal: SwapJournal) -> [String] {
        guard journal.namesAreValid else { return [] }
        var list: [String] = []
        if let name = journal.previousName { list.append(paths.previousDirectory + "/" + name) }
        if journal.request.mode == .update, SwapPaths.isStagingName(journal.request.stagedName) {
            list.append(SwapPaths.stagingDirectory(target: journal.request.target, name: journal.request.stagedName) + "/" + SwapPaths.bundleName)
        }
        if journal.request.mode == .goBack {
            list.append(paths.previousDirectory + "/" + SwapPaths.previousName(tag: journal.request.expectedTag))
        }
        return list
    }

    /// Executes `action` for `journal`.
    public func perform(_ action: ReconcileAction, journal: SwapJournal) -> ReconcileResult {
        guard action != .nothing, action != .leave, journal.namesAreValid else { return .carryOn }
        let store = JournalStore(paths: paths)
        guard let lock = store.lock() else { return .carryOn }
        defer { lock.release() }
        guard (try? store.prepare()) != nil else { return .carryOn }
        let target = journal.request.target
        let parentPath = (target as NSString).deletingLastPathComponent
        guard paths.allowedTargets.contains(target), let parentFD = FileOps.openDirectory(parentPath) else { return .carryOn }
        defer { close(parentFD) }
        guard let previousFD = FileOps.openDirectory(paths.previousDirectory) else { return .carryOn }
        defer { close(previousFD) }
        var updated = journal
        switch action {
        case .commit:
            keepOriginal(journal, parentFD: parentFD, previousFD: previousFD)
            removeStaging(journal, parentFD: parentFD)
            if let keep = journal.previousName { SwapEngine.prunePrevious(previousFD: previousFD, keep: keep) }
            updated.state = .committed
        case .discard, .forget:
            if action == .discard {
                returnIncoming(journal, parentFD: parentFD, previousFD: previousFD)
                // A crash between the record and the swap leaves a record
                // that names a copy which was never kept: the record in
                // force before the swap comes back, or none.
                if journal.state == .swapped || journal.state == .launched {
                    store.writeRecord(journal.priorRecord)
                }
            }
            removeStaging(journal, parentFD: parentFD)
            updated.state = .rolledBack
            updated.incoming = nil
        case .swapBack:
            guard let tag = journal.outgoingTag, let app = currentApp,
                  keepOriginal(journal, parentFD: parentFD, previousFD: previousFD)
            else { return .carryOn }
            removeStaging(journal, parentFD: parentFD)
            let failed = journal.request.mode == .update ? journal.request.expectedTag : journal.outgoingTag
            let request = SwapRequest(mode: .goBack, target: target, stagedName: "", expectedTag: tag,
                                      token: SwapRequest.newToken(), app: app, failedTag: failed)
            guard (try? store.write(SwapJournal(request: request))) != nil else { return .carryOn }
            lock.release()
            return spawnGoBack() ? .quitForSwapBack : .carryOn
        case .nothing, .leave:
            return .carryOn
        }
        _ = try? store.write(updated)
        return .carryOn
    }

    /// Moves the original bundle to its previous name when the swap left it
    /// in the staging directory. Returns whether it is at the previous name.
    @discardableResult
    private func keepOriginal(_ journal: SwapJournal, parentFD: Int32, previousFD: Int32) -> Bool {
        guard let original = journal.original, let name = journal.previousName else { return false }
        if FileIdentity.of(dirFD: previousFD, name: name) == original { return true }
        guard journal.request.mode == .update, SwapPaths.isStagingName(journal.request.stagedName),
              let stagingFD = FileOps.openDirectory(at: parentFD, journal.request.stagedName)
        else { return false }
        defer { close(stagingFD) }
        guard FileIdentity.of(dirFD: stagingFD, name: SwapPaths.bundleName) == original else { return false }
        if let existing = FileIdentity.of(dirFD: previousFD, name: name), existing != original, existing != journal.incoming {
            FileOps.removeTree(at: previousFD, name)
        }
        return renamer.move(fromDir: stagingFD, from: SwapPaths.bundleName, toDir: previousFD, to: name) == 0
    }

    /// Removes an update's staging directory, unless the original bundle is
    /// in it.
    private func removeStaging(_ journal: SwapJournal, parentFD: Int32) {
        let name = journal.request.stagedName
        guard journal.request.mode == .update, SwapPaths.isStagingName(name) else { return }
        if let original = journal.original, let fd = FileOps.openDirectory(at: parentFD, name) {
            let holdsOriginal = FileIdentity.of(dirFD: fd, name: SwapPaths.bundleName) == original
            close(fd)
            if holdsOriginal { return }
        }
        FileOps.removeTree(at: parentFD, name)
    }

    /// After a swap that did not stand: an update's incoming copy left under
    /// the previous name is removed; a go-back's previous copy goes back to
    /// its own name.
    private func returnIncoming(_ journal: SwapJournal, parentFD: Int32, previousFD: Int32) {
        guard let incoming = journal.incoming, let name = journal.previousName,
              FileIdentity.of(dirFD: previousFD, name: name) == incoming
        else { return }
        switch journal.request.mode {
        case .update:
            FileOps.removeTree(at: previousFD, name)
        case .goBack:
            _ = renamer.move(fromDir: previousFD, from: name, toDir: previousFD, to: SwapPaths.previousName(tag: journal.request.expectedTag))
        }
    }
}
