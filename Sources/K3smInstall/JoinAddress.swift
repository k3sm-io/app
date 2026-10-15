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

/// InterfaceAddress is one IPv4 address bound to a network interface, as the
/// app reads it from the system (`getifaddrs`), with the interface flags the
/// join address choice needs.
public struct InterfaceAddress: Hashable, Sendable {
    public let interface: String
    /// The dotted IPv4 address.
    public let address: String
    public let up: Bool
    public let running: Bool
    public let loopback: Bool
    public let pointToPoint: Bool

    public init(interface: String, address: String, up: Bool = true, running: Bool = true,
                loopback: Bool = false, pointToPoint: Bool = false) {
        self.interface = interface
        self.address = address
        self.up = up
        self.running = running
        self.loopback = loopback
        self.pointToPoint = pointToPoint
    }
}

/// JoinAddressSource is the one seam the server's join address comes from:
/// this Mac's IPv4 interface addresses. The app reads them with
/// `getifaddrs`; the tests pass a table.
public protocol JoinAddressSource: Sendable {
    func interfaceAddresses() -> [InterfaceAddress]
}

/// JoinAddressResolution is the address a joining Mac dials, or why there is
/// no single one.
public enum JoinAddressResolution: Equatable, Sendable {
    /// Exactly one underlay address.
    case one(ServerAddress)
    /// No underlay address: this Mac is on no local network.
    case none
    /// Several, which the app cannot choose between; sorted.
    case several([String])

    /// Why the action is disabled, or nil when there is one address.
    public var disabledReason: String? {
        switch self {
        case .one: return nil
        case .none:
            return "This Mac has no local network IPv4 address for another Mac to join. Use `sudo k3sm token create` in Terminal."
        case .several(let all):
            return "This Mac has several local network addresses (" + all.joined(separator: ", ")
                + "), so k3sm cannot tell which one the other Mac reaches, and Copy Join Command stays off while more than one"
                + " is active. A later version will let you choose the address; until then, use `sudo k3sm token create` in Terminal."
        }
    }
}

/// JoinAddress chooses the server's underlay (LAN) address for a join. The
/// join dials `<server>:9345` before the new node has any mesh, so the mesh
/// address (100.64.0.0/10) is never a candidate; nor is loopback, link-local,
/// multicast or a reserved address, a point-to-point tunnel, an interface
/// that is down, or a virtual machine bridge (the host side of a VM's NAT
/// network, which other Macs cannot reach). Exactly one remaining address
/// enables the action.
public enum JoinAddress {
    /// Interface name prefixes that never carry the underlay: loopback,
    /// tunnels, the VM NAT bridges and the Apple peer-to-peer links.
    public static let excludedInterfacePrefixes = ["lo", "utun", "bridge", "vmenet", "awdl", "llw", "anpi", "ap", "gif", "stf"]

    public static func resolve(_ source: any JoinAddressSource) -> JoinAddressResolution {
        select(source.interfaceAddresses())
    }

    public static func select(_ addresses: [InterfaceAddress]) -> JoinAddressResolution {
        var found: [String: ServerAddress] = [:]
        for a in addresses where isCandidate(a) {
            guard let server = try? ServerAddress(parsing: a.address), case .ipv4 = server.host else { continue }
            found[a.address] = server
        }
        switch found.count {
        case 0: return .none
        case 1: return .one(found.values.first!)
        default: return .several(found.keys.sorted())
        }
    }

    static func isCandidate(_ a: InterfaceAddress) -> Bool {
        guard a.up, a.running, !a.loopback, !a.pointToPoint else { return false }
        guard !excludedInterfacePrefixes.contains(where: { a.interface.hasPrefix($0) }) else { return false }
        guard let octets = ipv4Octets(a.address) else { return false }
        return isUnderlay(octets)
    }

    /// Reports whether an IPv4 address can be a LAN unicast address: not
    /// 0/8, loopback 127/8, link-local 169.254/16, the mesh 100.64/10,
    /// multicast 224/4 or reserved 240/4 (which holds the broadcast address).
    static func isUnderlay(_ o: [UInt8]) -> Bool {
        if o[0] == 0 || o[0] == 127 { return false }
        if o[0] == 169 && o[1] == 254 { return false }
        if o[0] == 100 && (o[1] & 0xC0) == 64 { return false }
        if o[0] >= 224 { return false }
        return true
    }

    static func ipv4Octets(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard (1...3).contains(p.count), p.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  !(p.count > 1 && p.first == "0"), let n = UInt8(p) else { return nil }
            out.append(n)
        }
        return out
    }
}
