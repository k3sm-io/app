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
import K3smInstall

/// InterfaceAddressSource reads this Mac's IPv4 interface addresses with
/// `getifaddrs`: the join address source behind Copy Join Command.
struct InterfaceAddressSource: JoinAddressSource {
    func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let flags = Int32(ifa.ifa_flags)
            out.append(InterfaceAddress(
                interface: String(cString: ifa.ifa_name),
                address: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                up: flags & IFF_UP != 0,
                running: flags & IFF_RUNNING != 0,
                loopback: flags & IFF_LOOPBACK != 0,
                pointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return out
    }
}
