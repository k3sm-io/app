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

/// SwapTimeouts bounds each wait of a swap.
public struct SwapTimeouts: Equatable, Sendable {
    /// How long the app has to exit after it asked for the swap.
    public var appExit: Duration
    /// How long the new app has to answer the handshake.
    public var handshake: Duration
    /// How long a terminated process has before it is killed, and again
    /// after the kill.
    public var terminate: Duration
    /// How often the handshake file is read.
    public var poll: Duration

    public init(appExit: Duration = .seconds(30), handshake: Duration = .seconds(60),
                terminate: Duration = .seconds(5), poll: Duration = .milliseconds(100)) {
        self.appExit = appExit
        self.handshake = handshake
        self.terminate = terminate
        self.poll = poll
    }

    /// The shipped bounds: 30 s for the app to exit, 60 s for the handshake.
    public static let standard = SwapTimeouts()
}

/// SwapClock is the engine's time source.
public protocol SwapClock: Sendable {
    func now() -> ContinuousClock.Instant
}

/// SystemSwapClock is the real `SwapClock`.
public struct SystemSwapClock: SwapClock {
    public init() {}

    public func now() -> ContinuousClock.Instant { ContinuousClock.now }
}

/// SwapFaultPhase says where in a journal step a fault point sits: right
/// after the state was written, or right after the act it names.
public enum SwapFaultPhase: Sendable, CaseIterable {
    case written
    case acted
}

/// SwapFaults is the tests' kill switch: a hook asked at every fault point,
/// which stops the engine on the spot, as a killed helper would stop, when it
/// returns true. The helper never sets it.
public struct SwapFaults: Sendable {
    public let stop: (@Sendable (JournalState, SwapFaultPhase) -> Bool)?

    public init(stop: (@Sendable (JournalState, SwapFaultPhase) -> Bool)?) {
        self.stop = stop
    }

    public static let none = SwapFaults(stop: nil)
}

/// SwapEngine replaces the installed app bundle with a verified one, and
/// puts it back when the new one does not come up. The order for `--swap`:
///
/// 1. Take the lock, read the request (the journal) and check every path in
///    it against `SwapPaths`; open the target's directory and the staging
///    directory once, so every rename after is relative to those
///    descriptors.
/// 2. Verify the staged bundle: the requirement, the bundle id, the team
///    stamp, a `K3smPayloadTag` equal to the requested one and strictly
///    above the installed bundle's, which is read from the installed bundle
///    and never from the request. Journal `verified` with both identities.
/// 3. Wait for the app to exit (`NOTE_EXIT`, with the start time). On a
///    timeout the update is abandoned: no rename, the staged copy kept, the
///    journal at `verified`.
/// 4. Verify the staged bundle again, journal `swapped`, then
///    `renameatx_np(RENAME_SWAP)`. Every errno is mapped (`RenameOutcome`);
///    `EXDEV` copies the staged bundle onto the target's volume, verifies the
///    copy and retries once.
/// 5. Move the old bundle at once to `previous/k3sm-<old tag>.previous`.
/// 6. Verify the target again, record its cdhash, journal `launched`, launch
///    it (LaunchServices), then wait for the handshake bound to that cdhash.
/// 7. On the handshake, journal `committed`, remove the staging directory and
///    any older previous copy. Without one, or when the new app exits early:
///    terminate it, re-verify the previous copy, journal `rolledBack`, swap
///    back, remove the new bundle, relaunch the old one with
///    `--update-failed <tag>`.
///
/// After the swap the engine reads into a bundle by path only for the
/// launch and the post-swap verification of the constant target, the
/// re-verification of the previous copy before a swap back, and the identity
/// assertions; every rename is relative to the directory descriptors.
/// Nothing writes into, truncates or re-signs a file inside either bundle:
/// every change is a rename of a whole directory.
///
/// `--go-back` is the same engine with the roles reversed: the incoming
/// bundle is the kept previous copy, it needs no floor, and the bundle it
/// replaces becomes the previous copy.
public struct SwapEngine: Sendable {
    public let requirement: String
    public let clock: any SwapClock
    public let watcher: any ProcessWatcher
    public let renamer: any Renamer
    public let launcher: any AppLauncher
    public let verifier: any BundleVerifier
    public let paths: SwapPaths
    public let timeouts: SwapTimeouts
    let faults: SwapFaults

    /// The engine with every seam given. The helper passes the compiled
    /// requirements and the real adapters; tests pass fixtures and doubles.
    public init(requirement: String, clock: any SwapClock, watcher: any ProcessWatcher, renamer: any Renamer,
                launcher: any AppLauncher, verifier: any BundleVerifier, paths: SwapPaths, timeouts: SwapTimeouts,
                faults: SwapFaults = .none) {
        self.requirement = requirement
        self.clock = clock
        self.watcher = watcher
        self.renamer = renamer
        self.launcher = launcher
        self.verifier = verifier
        self.paths = paths
        self.timeouts = timeouts
        self.faults = faults
    }

    /// Runs a `--swap` request.
    public func swap() -> SwapExit {
        finish(mode: .update)
    }

    /// Runs a `--go-back` request.
    public func goBack() -> SwapExit {
        finish(mode: .goBack)
    }

    /// Launches the target and waits for its handshake, with no rename and
    /// no swap back: the user-side half of the administrator path, which
    /// swapped as root. The journal is read for the token and the tags and
    /// is not written.
    public func relaunch() -> SwapExit {
        let store = JournalStore(paths: paths)
        guard let lock = store.lock() else { return store.privateDirectoryIsSafe() ? .busy : .refusedRequest }
        defer { lock.release() }
        guard let journal = try? store.read(), !journal.state.isTerminal, validate(journal.request) else {
            return .refusedRequest
        }
        let target = journal.request.target
        guard let post = try? verifier.verify(bundleAt: target, requireTag: true), post.tag == journal.request.expectedTag
        else { return .verificationFailed }
        let check = HandshakeCheck(paths: paths, requirement: requirement)
        check.clear()
        var arguments = [SwapLaunchArguments.handshake]
        if let old = journal.outgoingTag { arguments = [SwapLaunchArguments.updatedFrom, old] + arguments }
        guard let launched = try? launcher.launch(bundleAt: target, arguments: arguments) else { return .abandoned }
        let accepted = awaitHandshake(check: check, token: journal.request.token, launched: launched, cdhash: post.cdhash)
        SwapLog.handshake(accepted: accepted)
        return accepted ? .committed : .abandoned
    }

    private func finish(mode: SwapMode) -> SwapExit {
        let exit: SwapExit
        do {
            exit = try run(mode: mode)
        } catch {
            // A fault point stopped the engine where a kill would.
            return .abandoned
        }
        SwapLog.swap(exit)
        return exit
    }

    /// Killed is thrown at a fault point the tests stop at.
    struct Killed: Error {}

    private func fault(_ state: JournalState, _ phase: SwapFaultPhase) throws(Killed) {
        if faults.stop?(state, phase) == true { throw Killed() }
    }

    /// Slot is one bundle location: a directory descriptor, its path and an
    /// entry name in it.
    struct Slot {
        let dirFD: Int32
        let dirPath: String
        let name: String

        var path: String { dirPath + "/" + name }
        var identity: FileIdentity? { FileIdentity.of(dirFD: dirFD, name: name) }
    }

    /// Whether a request names only what `SwapPaths` allows.
    func validate(_ request: SwapRequest) -> Bool {
        guard paths.allowedTargets.contains(request.target), paths.refusal(target: request.target) == nil,
              SwapTag.isReleaseTag(request.expectedTag),
              request.token.utf8.count == 64, request.token.utf8.allSatisfy({ isHexDigit($0) }),
              request.failedTag.map(SwapTag.isReleaseTag) ?? true
        else { return false }
        switch request.mode {
        case .update: return SwapPaths.isStagingName(request.stagedName)
        case .goBack: return request.stagedName.isEmpty
        }
    }

    private func isHexDigit(_ b: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(b)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func run(mode: SwapMode) throws(Killed) -> SwapExit {
        let store = JournalStore(paths: paths)
        guard store.privateDirectoryIsSafe() else { return .refusedRequest }
        guard let lock = store.lock() else { return .busy }
        defer { lock.release() }
        guard var journal = try? store.read(), journal.state == .staged, journal.request.mode == mode,
              validate(journal.request)
        else { return .refusedRequest }
        let request = journal.request
        guard (try? store.prepare()) != nil else { return .refusedRequest }

        let target = request.target
        let parentPath = (target as NSString).deletingLastPathComponent
        guard let parentFD = FileOps.openDirectory(parentPath) else { return .refusedRequest }
        defer { close(parentFD) }
        guard let previousFD = FileOps.openDirectory(paths.previousDirectory) else { return .refusedRequest }
        defer { close(previousFD) }
        guard FileOps.isDirectory(at: parentFD, SwapPaths.bundleName), let original = FileIdentity.of(dirFD: parentFD, name: SwapPaths.bundleName)
        else { return .refusedRequest }
        let targetSlot = Slot(dirFD: parentFD, dirPath: parentPath, name: SwapPaths.bundleName)

        // The incoming bundle's location, opened once.
        var stagingFDs: [Int32] = []
        defer { stagingFDs.forEach { close($0) } }
        // Every staging directory this run used, removed at the end.
        var stagingNames: [String] = mode == .update ? [request.stagedName] : []
        var incoming: Slot
        switch mode {
        case .update:
            guard let fd = FileOps.openDirectory(at: parentFD, request.stagedName) else { return .refusedRequest }
            stagingFDs.append(fd)
            incoming = Slot(dirFD: fd, dirPath: parentPath + "/" + request.stagedName, name: SwapPaths.bundleName)
        case .goBack:
            incoming = Slot(dirFD: previousFD, dirPath: paths.previousDirectory, name: SwapPaths.previousName(tag: request.expectedTag))
        }
        guard FileOps.isDirectory(at: incoming.dirFD, incoming.name) else { return .refusedRequest }

        // The floor and the outgoing tag come from the installed bundle.
        guard let installed = InstalledRelease.read(bundleAt: target) else {
            return afterAppExit(request, .verificationFailed)
        }
        guard let first = verifyIncoming(incoming, request: request, installed: installed, mode: mode) else {
            return afterAppExit(request, .verificationFailed)
        }
        journal.helper = ProcessIdentity.current()
        journal.original = original
        journal.incoming = first.identity
        journal.outgoingTag = installed.tag
        journal.previousName = SwapPaths.previousName(tag: installed.tag)
        journal.state = .verified
        guard save(store, journal) else { return afterAppExit(request, .abandoned) }
        try fault(.verified, .written)

        // The app must be gone before its bundle is renamed.
        guard watcher.waitForExit(request.app, timeout: timeouts.appExit) else { return .abandoned }

        // The second check, right before the swap.
        guard let second = verifyIncoming(incoming, request: request, installed: installed, mode: mode),
              second.identity == first.identity, targetSlot.identity == original
        else { return relaunchOriginal(request, .verificationFailed) }
        try fault(.verified, .acted)

        journal.state = .swapped
        guard save(store, journal) else { return relaunchOriginal(request, .abandoned) }
        try fault(.swapped, .written)
        var outcome = RenameOutcome(errno: renamer.swap(fromDir: incoming.dirFD, from: incoming.name, toDir: parentFD, to: targetSlot.name))
        if outcome == .crossDevice, mode == .update {
            // Copy the staged bundle onto the target's volume, verify the
            // copy, and retry once.
            let name = SwapPaths.newStagingName()
            if mkdirat(parentFD, name, 0o700) == 0, let fd = FileOps.openDirectory(at: parentFD, name) {
                stagingFDs.append(fd)
                stagingNames.append(name)
                let copy = Slot(dirFD: fd, dirPath: parentPath + "/" + name, name: SwapPaths.bundleName)
                if DittoCopier.copy(from: incoming.path, to: copy.path),
                   let third = verifyIncoming(copy, request: request, installed: installed, mode: mode) {
                    journal.request.stagedName = name
                    journal.incoming = third.identity
                    if save(store, journal) {
                        incoming = copy
                        outcome = RenameOutcome(errno: renamer.swap(fromDir: incoming.dirFD, from: incoming.name, toDir: parentFD, to: targetSlot.name))
                    }
                } else {
                    FileOps.removeTree(at: parentFD, name)
                }
            }
        }
        switch outcome {
        case .done:
            break
        case .unsupportedVolume, .needsAdministrator, .failed, .crossDevice:
            journal.state = .verified
            _ = save(store, journal)
            let exit: SwapExit = switch outcome {
            case .unsupportedVolume: .unsupportedVolume
            case .needsAdministrator: .needsAdministrator
            default: .abandoned
            }
            return relaunchOriginal(request, exit)
        }
        try fault(.swapped, .acted)

        // The swap must have put exactly these two bundles where expected.
        guard targetSlot.identity == journal.incoming, incoming.identity == original else {
            return rollBack(&journal, store: store, stagingNames: stagingNames, target: targetSlot, incoming: incoming, previousFD: previousFD, launched: nil)
        }
        // The old bundle leaves the Applications directory at once.
        let previousName = journal.previousName ?? SwapPaths.previousName(tag: installed.tag)
        if incoming.dirFD != previousFD || incoming.name != previousName {
            if let existing = FileIdentity.of(dirFD: previousFD, name: previousName),
               existing != original, existing != journal.incoming {
                FileOps.removeTree(at: previousFD, previousName)
            }
            guard renamer.move(fromDir: incoming.dirFD, from: incoming.name, toDir: previousFD, to: previousName) == 0 else {
                return rollBack(&journal, store: store, stagingNames: stagingNames, target: targetSlot, incoming: incoming, previousFD: previousFD, launched: nil)
            }
        }
        let outgoing = Slot(dirFD: previousFD, dirPath: paths.previousDirectory, name: previousName)
        return try launchAndConfirm(journal: &journal, store: store, stagingNames: stagingNames, target: targetSlot, incoming: incoming,
                                    outgoing: outgoing, previousFD: previousFD, parentFD: parentFD)
    }

    // swiftlint:disable:next function_parameter_count
    private func launchAndConfirm(journal: inout SwapJournal, store: JournalStore, stagingNames: [String], target: Slot,
                                  incoming: Slot, outgoing: Slot, previousFD: Int32, parentFD: Int32) throws(Killed) -> SwapExit {
        let request = journal.request
        // The post-swap verification of the constant target, whose cdhash
        // the handshake binds to.
        guard let post = try? verifier.verify(bundleAt: request.target, requireTag: request.mode == .update),
              post.identity == journal.incoming, tagMatches(post, path: request.target, tag: request.expectedTag)
        else {
            let exit = rollBack(&journal, store: store, stagingNames: stagingNames, target: target, incoming: incoming, previousFD: previousFD, launched: nil)
            return exit == .rolledBack ? .verificationFailed : exit
        }
        let check = HandshakeCheck(paths: paths, requirement: requirement)
        check.clear()
        journal.state = .launched
        guard save(store, journal) else {
            return rollBack(&journal, store: store, stagingNames: stagingNames, target: target, incoming: incoming, previousFD: previousFD, launched: nil)
        }
        try fault(.launched, .written)
        var arguments = [SwapLaunchArguments.updatedFrom, journal.outgoingTag ?? "", SwapLaunchArguments.handshake]
        if let failed = request.failedTag {
            arguments = [SwapLaunchArguments.updateFailed, failed, SwapLaunchArguments.handshake]
        }
        guard let launched = try? launcher.launch(bundleAt: request.target, arguments: arguments) else {
            return rollBack(&journal, store: store, stagingNames: stagingNames, target: target, incoming: incoming, previousFD: previousFD, launched: nil)
        }
        journal.launched = launched
        _ = save(store, journal)
        try fault(.launched, .acted)

        let accepted = awaitHandshake(check: check, token: request.token, launched: launched, cdhash: post.cdhash)
        SwapLog.handshake(accepted: accepted)
        guard accepted else {
            return rollBack(&journal, store: store, stagingNames: stagingNames, target: target, incoming: incoming, previousFD: previousFD, launched: launched)
        }
        journal.state = .committed
        _ = save(store, journal)
        try fault(.committed, .written)
        stagingNames.forEach { FileOps.removeTree(at: parentFD, $0) }
        Self.prunePrevious(previousFD: previousFD, keep: outgoing.name)
        check.clear()
        try fault(.committed, .acted)
        return .committed
    }

    /// Removes every previous copy but `keep`; only names of the previous
    /// grammar are touched.
    static func prunePrevious(previousFD: Int32, keep: String) {
        for name in FileOps.entries(previousFD) where name != keep && SwapPaths.tag(ofPreviousName: name) != nil {
            FileOps.removeTree(at: previousFD, name)
        }
    }

    /// Puts the original bundle back at the target and relaunches it. The
    /// original is found by its identity, in the previous root or where the
    /// swap left it, and verified again before the swap back.
    // swiftlint:disable:next function_parameter_count
    private func rollBack(_ journal: inout SwapJournal, store: JournalStore, stagingNames: [String], target: Slot,
                          incoming: Slot, previousFD: Int32, launched: ProcessIdentity?) -> SwapExit {
        let request = journal.request
        if let launched { terminate(launched) }
        let candidates = [Slot(dirFD: previousFD, dirPath: paths.previousDirectory, name: journal.previousName ?? ""), incoming]
        guard let original = journal.original,
              let outgoing = candidates.first(where: { !$0.name.isEmpty && $0.identity == original }),
              let verified = try? verifier.verify(bundleAt: outgoing.path, requireTag: false),
              verified.identity == original
        else {
            SwapLog.rollback(succeeded: false)
            return .abandoned
        }
        journal.state = .rolledBack
        _ = save(store, journal)
        if (try? fault(.rolledBack, .written)) == nil { return .abandoned }
        guard renamer.swap(fromDir: outgoing.dirFD, from: outgoing.name, toDir: target.dirFD, to: target.name) == 0 else {
            SwapLog.rollback(succeeded: false)
            return .abandoned
        }
        if (try? fault(.rolledBack, .acted)) == nil { return .abandoned }
        // The incoming bundle now sits where the original was: an update's
        // is removed with its staging directory, a go-back's previous copy
        // goes back to its own name.
        switch request.mode {
        case .update:
            if outgoing.dirFD != incoming.dirFD, outgoing.identity == journal.incoming {
                FileOps.removeTree(at: outgoing.dirFD, outgoing.name)
            }
            stagingNames.forEach { FileOps.removeTree(at: target.dirFD, $0) }
        case .goBack:
            if outgoing.name != incoming.name || outgoing.dirFD != incoming.dirFD {
                _ = renamer.move(fromDir: outgoing.dirFD, from: outgoing.name, toDir: incoming.dirFD, to: incoming.name)
            }
        }
        SwapLog.rollback(succeeded: true)
        _ = try? launcher.launch(bundleAt: request.target, arguments: [SwapLaunchArguments.updateFailed, request.expectedTag])
        return .rolledBack
    }

    /// Terminates a launched process: SIGTERM, then SIGKILL after the bound.
    private func terminate(_ process: ProcessIdentity) {
        guard process.isRunning else { return }
        kill(process.pid, SIGTERM)
        if !watcher.waitForExit(process, timeout: timeouts.terminate), process.isRunning {
            kill(process.pid, SIGKILL)
            _ = watcher.waitForExit(process, timeout: timeouts.terminate)
        }
    }

    /// Waits for the app to exit, then relaunches the original target with
    /// `--update-failed`, and returns `exit`. For a failure found before the
    /// wait: the app is quitting either way, and must come back.
    private func afterAppExit(_ request: SwapRequest, _ exit: SwapExit) -> SwapExit {
        guard watcher.waitForExit(request.app, timeout: timeouts.appExit) else { return exit }
        return relaunchOriginal(request, exit)
    }

    /// Relaunches the target, which still holds the original bundle, with
    /// `--update-failed <tag>`, and returns `exit`.
    private func relaunchOriginal(_ request: SwapRequest, _ exit: SwapExit) -> SwapExit {
        _ = try? launcher.launch(bundleAt: request.target, arguments: [SwapLaunchArguments.updateFailed, request.expectedTag])
        return exit
    }

    /// Verifies an incoming bundle. An update's must carry a
    /// `K3smPayloadTag` equal to the requested tag and strictly above the
    /// installed release; a go-back's is the kept previous copy, whose tag
    /// (its own, or its short version's for a bundle that predates the key)
    /// must equal the one its name and the request carry, and differ from
    /// the installed one.
    private func verifyIncoming(_ slot: Slot, request: SwapRequest, installed: InstalledRelease, mode: SwapMode) -> VerifiedBundle? {
        guard let verified = try? verifier.verify(bundleAt: slot.path, requireTag: mode == .update),
              verified.identity == slot.identity
        else { return nil }
        switch mode {
        case .update:
            guard verified.tag == request.expectedTag, let version = verified.version, version > installed.version else { return nil }
        case .goBack:
            guard tagMatches(verified, path: slot.path, tag: request.expectedTag), request.expectedTag != installed.tag else { return nil }
        }
        return verified
    }

    /// Whether a verified bundle carries `tag`: its `K3smPayloadTag`, or, for
    /// a bundle without one, its short version.
    private func tagMatches(_ verified: VerifiedBundle, path: String, tag: String) -> Bool {
        if let own = verified.tag { return own == tag }
        return InstalledRelease.read(bundleAt: path)?.tag == tag
    }

    private func save(_ store: JournalStore, _ journal: SwapJournal) -> Bool {
        (try? store.write(journal)) != nil
    }

    /// Reads the handshake file until it holds an acceptable answer, the
    /// launched process exits, or the bound passes.
    private func awaitHandshake(check: HandshakeCheck, token: String, launched: ProcessIdentity, cdhash: Data) -> Bool {
        let deadline = clock.now().advanced(by: timeouts.handshake)
        while true {
            if check.accepts(token: token, launched: launched, cdhash: cdhash) { return true }
            if watcher.waitForExit(launched, timeout: timeouts.poll) { return false }
            if clock.now() >= deadline { return false }
        }
    }
}
