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
import K3smStatus

/// AgentJoinTarget reads the control plane an installed worker joins, from
/// the `--server` argument of its LaunchDaemon plist. A worker update must
/// pass `--agent --server <host>` again (the CLI re-derives both from its
/// flags). `k3sm status -o json` carries the join target as `joinTarget`, and
/// that is read first; the plist launchd runs is the fallback for a CLI that
/// does not report it: the same source `k3sm uninstall` reads. The plist is
/// root-owned and world-readable (0644); the value still passes the strict `ServerAddress` grammar before use.
public enum AgentJoinTarget {
    /// The installed worker's plist.
    public static let plistPath = "/Library/LaunchDaemons/\(NodeRole.agent.daemonLabel).plist"

    /// ReadError says why no join target could be read.
    public enum ReadError: Error, Equatable, Sendable {
        case notAPlist
        case noProgramArguments
        case noServerFlag
        case invalidServer(ServerAddress.ParseError)
        /// `joinTarget` in the status report was present but not `host:port`
        /// with a host that passes the `ServerAddress` grammar.
        case invalidStatusTarget
    }

    /// The control plane a worker joins. The status report's `joinTarget`
    /// (`host:port`) is the source: the port is dropped, because the update
    /// passes `--server <host>` and the CLI adds the join port itself, and the
    /// host passes `ServerAddress`. Only when the field is absent does the
    /// installed plist stand in, read lazily. A present but malformed field is
    /// an error, never a silent fallback to a different source.
    public static func resolve(
        statusJoinTarget: String?, plist: () -> Data?
    ) -> Result<ServerAddress, ReadError> {
        if let statusJoinTarget {
            return host(ofJoinTarget: statusJoinTarget).map { .success($0) } ?? .failure(.invalidStatusTarget)
        }
        guard let data = plist() else { return .failure(.notAPlist) }
        do {
            return .success(try read(plist: data))
        } catch {
            return .failure(error)
        }
    }

    /// The host of a `host:port` join target, as a `ServerAddress`; nil for
    /// anything else (no port, a non-numeric port, a second colon).
    static func host(ofJoinTarget text: String) -> ServerAddress? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (0x30...0x39).contains($0) })
        else { return nil }
        return try? ServerAddress(parsing: String(parts[0]))
    }

    /// Returns the join target in the plist bytes.
    public static func read(plist data: Data) throws(ReadError) -> ServerAddress {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .notAPlist
        }
        guard let dict = object as? [String: Any], let args = dict["ProgramArguments"] as? [String] else {
            throw .noProgramArguments
        }
        guard let value = serverValue(args), !value.isEmpty else { throw .noServerFlag }
        // The CLI writes a bare host; an IPv6 address (two or more colons)
        // goes in brackets for the grammar, and `argument` takes them off.
        let ipv6 = value.filter { $0 == ":" }.count >= 2 && !value.hasPrefix("[")
        let text = ipv6 ? "[\(value)]" : value
        do {
            return try ServerAddress(parsing: text)
        } catch {
            throw .invalidServer(error)
        }
    }

    /// The value of the first `-server`/`--server` flag, in either the
    /// separate-word or the `=` form Go's flag package accepts: the CLI's own
    /// reading of the plist (`AgentJoinServer`) takes the first as well.
    static func serverValue(_ args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == "--server" || a == "-server" {
                return i + 1 < args.count ? args[i + 1] : ""
            }
            for prefix in ["--server=", "-server="] where a.hasPrefix(prefix) {
                return String(a.dropFirst(prefix.count))
            }
        }
        return nil
    }
}
