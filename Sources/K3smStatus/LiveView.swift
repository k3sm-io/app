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

/// LiveView names the two live Terminal views the menu opens and the CLI
/// argument lists behind them: `k3sm status -o wide --watch=2s` and
/// `k3sm status top --watch=2s`. Both redraw in place until Control-C. The
/// top view is newer than the status watch, so the menu offers it only when
/// the installed CLI answers `LiveTopProbe`.
public enum LiveView: String, CaseIterable, Sendable {
    case status
    case top

    /// The watch interval both views ask for, in the CLI's duration syntax.
    public static let interval = "2s"

    /// The CLI arguments the view's `.command` runs.
    public var arguments: [String] {
        switch self {
        case .status: return ["status", "-o", "wide", "--watch=" + Self.interval]
        case .top: return ["status", "top", "--watch=" + Self.interval]
        }
    }

    /// The menu item that opens the view.
    public var menuTitle: String {
        switch self {
        case .status: return "Live Status in Terminal"
        case .top: return "Live Top in Terminal"
        }
    }

    /// The view's name, as the hint, the Terminal title and the stopped line
    /// say it.
    public var name: String {
        switch self {
        case .status: return "k3sm status"
        case .top: return "k3sm top"
        }
    }

    /// The Terminal tab's title while the view runs.
    public var liveTitle: String { name + " (live)" }

    /// The Terminal tab's title once the view has exited.
    public var stoppedTitle: String { name + " (stopped)" }

    /// The one line printed before the view starts.
    public var hint: String { name + ", live: refreshes every 2 s. Control-C to stop." }

    /// The line printed when the view ends on Control-C or on its own.
    public var stoppedLine: String { name + " stopped. Close this window, or open it again from the k3sm menu." }
}

/// LiveTopProbe decides whether the menu offers Live Top: the installed CLI
/// has the view when `k3sm status top --help` exits 0. The probe runs only
/// through the trust-checked CLI, and its output is never read. An answer is
/// kept for one CLI binary (`Identity`), so the probe runs again only when the
/// binary at the CLI path changes; a run that gave no answer (killed, refused,
/// missing) hides the item and is not kept.
public enum LiveTopProbe {
    /// The probe's argument list.
    public static let arguments = ["status", "top", "--help"]

    /// What one probe run produced.
    public enum Outcome: Equatable, Sendable {
        /// The CLI exited with this status.
        case exited(Int32)
        /// The CLI did not answer: it was missing, killed, failed to start,
        /// wrote past its limit, or failed its trust check.
        case noAnswer
    }

    /// Whether an outcome offers the view.
    public static func offered(_ outcome: Outcome) -> Bool {
        outcome == .exited(0)
    }

    /// The installed CLI binary's identity, from `lstat`: a reinstall or an
    /// update replaces the file, which changes at least one of these.
    public struct Identity: Equatable, Sendable {
        public let device: Int64
        public let inode: UInt64
        public let size: Int64
        public let modified: Int64
        public let modifiedNanos: Int64
        public let changed: Int64
        public let changedNanos: Int64

        public init(device: Int64, inode: UInt64, size: Int64, modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modified = modified
            self.modifiedNanos = modifiedNanos
            self.changed = changed
            self.changedNanos = changedNanos
        }
    }

    /// The kept answer for one binary.
    public struct Cache: Equatable, Sendable {
        private var identity: Identity?
        private var answer = false

        public init() {}

        /// The kept answer for this binary, or nil when the probe must run:
        /// nothing kept, a different binary, or no binary to identify.
        public func offered(for identity: Identity?) -> Bool? {
            guard let identity, identity == self.identity else { return nil }
            return answer
        }

        /// Records one run for the binary it ran against and returns whether
        /// the item is shown. Only an exit status is kept.
        public mutating func record(_ outcome: Outcome, for identity: Identity?) -> Bool {
            let shown = LiveTopProbe.offered(outcome)
            if case .exited = outcome, let identity {
                self.identity = identity
                answer = shown
            } else {
                self.identity = nil
                answer = false
            }
            return shown
        }
    }
}
