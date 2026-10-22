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

import Foundation
import K3smInstall
import K3smStatus

/// AppUpdateChecker is one check for a new release of the app: fetch the
/// signed index (`IndexSource`), verify it (`verify`, the pinned
/// `ReleaseIndexVerifier` in the shipped checker), hold it to
/// `AppUpdateAcceptance` against the stored high-water pair, store the new
/// pair and the check's time, and decide the state (`AppUpdateState`).
///
/// It only reads. It has no runner and starts nothing: no root step, no
/// roll, no install. A test holds that its sources name none of those
/// types. With checks off it makes no request unless the user asked
/// (`check(userInitiated: true)`, Check Now), and a development build never
/// makes one. Only the `(tag, issuedAt)` pair and the check's time are
/// stored; the verified index comes back in `Result.verified`, for this
/// process to keep in memory.
public struct AppUpdateChecker<Verified: Sendable>: Sendable {
    /// The signature check: the index's bytes in, the verified index out,
    /// or a throw that the check reports as "could not check".
    public typealias Verify = @Sendable (Data) throws -> Verified

    /// What one check returns.
    public struct Result: Sendable {
        public let state: AppUpdateState
        /// The outcome to decide later states from; nil when no check ran.
        public let outcome: AppUpdateCheckOutcome?
        /// The verified index, for this process only; nil unless accepted.
        public let verified: Verified?
    }

    let source: any IndexSource
    let verify: Verify
    let facts: @Sendable (Verified) -> AppIndexFacts
    let preferences: AppPreferences
    let ownTag: String?
    let pinned: Bool
    let clock: @Sendable () -> Date

    /// A checker with every seam given: the tests' initializer.
    init(source: any IndexSource, verify: @escaping Verify, facts: @escaping @Sendable (Verified) -> AppIndexFacts,
         preferences: AppPreferences, ownTag: String?, pinned: Bool, clock: @escaping @Sendable () -> Date) {
        self.source = source
        self.verify = verify
        self.facts = facts
        self.preferences = preferences
        self.ownTag = ownTag
        self.pinned = pinned
        self.clock = clock
    }

    /// Runs one check. `userInitiated` is Check Now or Check for Updates,
    /// which runs with automatic checks off too.
    public func check(userInitiated: Bool) async -> Result {
        let checksOn = preferences.checkAppUpdates
        func state(_ outcome: AppUpdateCheckOutcome?) -> AppUpdateState {
            AppUpdateState.decide(ownTag: ownTag, pinned: pinned, checksOn: checksOn, outcome: outcome,
                                  stored: preferences.appIndexHighWater.pair)
        }
        let early = state(nil)
        if early == .development { return Result(state: early, outcome: nil, verified: nil) }
        guard checksOn || userInitiated else { return Result(state: early, outcome: nil, verified: nil) }

        AppUpdateLog.logger.notice("app update: check started")
        let p7m: Data
        do {
            p7m = try await source.fetch()
        } catch {
            return failed(error.description, state)
        }
        let verified: Verified
        do {
            verified = try verify(p7m)
        } catch {
            return failed("could not verify the release index: " + String(describing: error), state)
        }
        let index = facts(verified)
        let stored = preferences.appIndexHighWater
        if stored == .garbage {
            AppUpdateLog.logger.notice("app update: the stored high-water mark is unreadable; treated as absent")
        }
        switch AppUpdateAcceptance.accept(tag: index.tag, issuedAt: index.issuedAt, signedAt: index.signedAt,
                                          stored: stored.pair, ownTag: ownTag) {
        case .refused(let refusal):
            return failed(refusal.description, state)
        case .belowRunning:
            // Verified and current, but not newer than this build: a
            // successful check whose index is never stored.
            preferences.appUpdateLastCheck = clock()
            AppUpdateLog.accepted(tag: index.tag)
            let outcome = AppUpdateCheckOutcome.accepted(index)
            return Result(state: state(outcome), outcome: outcome, verified: verified)
        case .accepted(let pair):
            preferences.storeHighWater(pair)
            preferences.appUpdateLastCheck = clock()
            AppUpdateLog.accepted(tag: index.tag)
            let outcome = AppUpdateCheckOutcome.accepted(index)
            return Result(state: state(outcome), outcome: outcome, verified: verified)
        }
    }

    private func failed(_ reason: String, _ state: (AppUpdateCheckOutcome?) -> AppUpdateState) -> Result {
        AppUpdateLog.refused(reason)
        let outcome = AppUpdateCheckOutcome.failed(reason)
        return Result(state: state(outcome), outcome: outcome, verified: nil)
    }
}

extension AppUpdateChecker where Verified == ReleaseIndexVerifier.VerifiedReleaseIndex {
    /// The shipped checker: the fixed request, the verifier for the team
    /// this binary pins, the running bundle's sealed payload tag, this Mac's
    /// macOS and the wall clock. Nil for a development build, which has no
    /// pin and never checks.
    public static func shipped(preferences: AppPreferences, ownTag: String?) -> AppUpdateChecker? {
        guard let verifier = ReleaseIndexVerifier.pinned else { return nil }
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        return AppUpdateChecker(
            source: URLSessionIndexSource(),
            verify: { p7m in try verifier.verified(p7m: p7m) },
            facts: { AppIndexFacts(index: $0.index, signedAt: $0.signedAt, macOS: macOS) },
            preferences: preferences, ownTag: ownTag, pinned: true, clock: { Date() })
    }
}
