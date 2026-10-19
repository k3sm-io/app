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

import os

/// SwapExit names the helper's exit statuses, one per outcome, in the
/// pattern of `CopyOutExit`.
///
/// The app that asked for the swap has quit and the helper runs in its own
/// session, so nobody reads this status but a caller that waits for it (the
/// administrator path, the tests). The relaunched app learns the outcome from
/// the journal: its state and its `reason`, one of these values.
public enum SwapExit: Int32, Codable, Sendable, CaseIterable {
    /// The new bundle is in place and answered the handshake (or, for
    /// `--relaunch`, the relaunched app answered).
    case committed = 0
    /// The request, its directory or the helper's own location was refused;
    /// nothing was renamed.
    case refusedRequest = 64
    /// A bundle failed verification, or is not newer than the installed one;
    /// nothing was renamed, or the swap was undone before any launch.
    case verificationFailed = 65
    /// The rename was refused with `EPERM`: the administrator path is needed.
    /// The old bundle is in place and the journal is at `verified`.
    case needsAdministrator = 66
    /// The volume cannot swap two names in one step (`VOL_CAP_INT_RENAME_SWAP`
    /// absent, or `ENOTSUP`), or the previous root is on another volume.
    case unsupportedVolume = 67
    /// The new bundle did not answer, or exited early; the old one is back
    /// in place and was relaunched.
    case rolledBack = 68
    /// The update stopped without a swap: the app did not exit in time, or
    /// the rename failed with another errno. The staged copy is kept.
    case abandoned = 69
    /// The target's volume is read-only (`EROFS`).
    case readOnlyVolume = 70
    /// Another helper holds the lock.
    case busy = 75
}

/// SwapLog is the update's os_log: one event each for the swap, the
/// handshake, the reconcile and the rollback, under the subsystem
/// `io.k3sm.app.update`, each a static message.
enum SwapLog {
    static let logger = Logger(subsystem: "io.k3sm.app.update", category: "swap")

    static func swap(_ exit: SwapExit) {
        switch exit {
        case .committed: logger.notice("swap: committed")
        case .refusedRequest: logger.error("swap: request refused")
        case .verificationFailed: logger.error("swap: verification failed")
        case .needsAdministrator: logger.error("swap: rename refused, needs an administrator")
        case .unsupportedVolume: logger.error("swap: the volume cannot swap in one step")
        case .readOnlyVolume: logger.error("swap: the volume is read-only")
        case .rolledBack: logger.error("swap: rolled back")
        case .abandoned: logger.error("swap: abandoned, nothing replaced")
        case .busy: logger.notice("swap: another helper is running")
        }
    }

    static func handshake(accepted: Bool) {
        if accepted {
            logger.notice("handshake: accepted from the launched app")
        } else {
            logger.error("handshake: none from the launched app")
        }
    }

    static func reconcile(_ action: ReconcileAction) {
        switch action {
        case .nothing: logger.debug("reconcile: nothing to do")
        case .commit: logger.notice("reconcile: committed an interrupted swap")
        case .discard: logger.notice("reconcile: discarded a swap that did not happen")
        case .swapBack: logger.notice("reconcile: swapping back an unconfirmed swap")
        case .forget: logger.notice("reconcile: the target was replaced by something else; forgot the swap")
        case .leave: logger.error("reconcile: neither bundle verifies; left as is")
        }
    }

    static func rollback(succeeded: Bool) {
        if succeeded {
            logger.notice("rollback: the previous bundle is back in place")
        } else {
            logger.fault("rollback: could not put the previous bundle back")
        }
    }
}
