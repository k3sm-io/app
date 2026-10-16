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

/// ServiceRow is one Service as the Services tab lists it: where it is, its
/// type and cluster IP, its ports as kubectl prints them, and the hosts of
/// the Ingresses that route to it. Every string is clipped.
public struct ServiceRow: Equatable, Sendable {
    /// "namespace/name", unique per row.
    public let key: String
    public let namespace: String
    public let name: String
    /// The Service's type; "ClusterIP" when the API leaves it out.
    public let type: String
    /// The cluster IP, "None" for a headless Service, "" when unset.
    public let clusterIP: String
    /// Each port as "80/TCP", or "80:30080/TCP" with its node port.
    public let ports: [String]
    /// The hosts of the Ingresses in its namespace that send traffic to it,
    /// sorted; "*" for a rule or default backend that matches any host.
    public let hosts: [String]

    /// The ports on one line, as the row shows them.
    public var portsText: String { ports.isEmpty ? "-" : ports.joined(separator: ", ") }
    /// The hosts on one line, as the row shows them.
    public var hostsText: String { hosts.isEmpty ? "-" : hosts.joined(separator: ", ") }
}

/// ServicesList decodes `K3smCLI.servicesArguments`, kubectl's `List` of
/// Services and Ingresses across namespaces, into the Services tab's rows.
/// An Ingress is not a row of its own: its hosts are attached to the
/// Services its backends name in the same namespace.
public enum ServicesList {
    /// The tab's line when the cluster has no Service.
    public static let emptyText = "No services on the cluster."

    /// The rows, sorted by namespace and name. It throws `KubeListError`
    /// when the bytes are not a list of Services and Ingresses.
    public static func decode(_ data: Data) throws -> [ServiceRow] {
        let objects = try KubeList.objects(data, kinds: ["Service", "Ingress"])
        var hosts: [String: Set<String>] = [:]
        for ingress in objects where ingress["kind"] as? String == "Ingress" {
            let namespace = KubeList.namespace(ingress)
            for (service, host) in routes(of: ingress) {
                hosts["\(namespace)/\(service)", default: []].insert(host)
            }
        }
        let rows = objects.filter { $0["kind"] as? String == "Service" }.map { service -> ServiceRow in
            let namespace = KubeList.namespace(service)
            let name = KubeList.name(service)
            let spec = KubeList.dict(service, "spec")
            return ServiceRow(
                key: StatusDisplay.clip("\(namespace)/\(name)"),
                namespace: StatusDisplay.clip(namespace),
                name: StatusDisplay.clip(name),
                type: StatusDisplay.clip(KubeList.string(spec, "type") ?? "ClusterIP"),
                clusterIP: StatusDisplay.clip(KubeList.string(spec, "clusterIP") ?? ""),
                ports: KubeList.array(spec, "ports").compactMap(port(_:)),
                hosts: (hosts["\(namespace)/\(name)"] ?? []).map(StatusDisplay.clip).sorted())
        }
        return rows.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// One list run as a tab result.
    public static func tabResult(exitCode: Int32, stdout: Data) -> TabResult<[ServiceRow]> {
        KubeList.tabResult(exitCode: exitCode, stdout: stdout, what: "service list", decode: decode)
    }

    /// The rows the search leaves visible: all for an empty query, else those
    /// whose namespace, name or a host contains it, case ignored.
    public static func visible(_ rows: [ServiceRow], query: String) -> [ServiceRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            ([row.namespace, row.name] + row.hosts).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// A port as kubectl's PORT(S) column prints it.
    static func port(_ port: [String: Any]) -> String? {
        guard let number = KubeList.int(port, "port") else { return nil }
        let proto = StatusDisplay.clip(KubeList.string(port, "protocol") ?? "TCP")
        if let node = KubeList.int(port, "nodePort") { return "\(number):\(node)/\(proto)" }
        return "\(number)/\(proto)"
    }

    /// The (service, host) pairs an Ingress routes: each rule's host (or "*")
    /// to each of its paths' backend Services, and the default backend's
    /// Service to "*".
    static func routes(of ingress: [String: Any]) -> [(String, String)] {
        let spec = KubeList.dict(ingress, "spec")
        var out: [(String, String)] = []
        for rule in KubeList.array(spec, "rules") {
            let host = KubeList.string(rule, "host") ?? "*"
            for path in KubeList.array(KubeList.dict(rule, "http"), "paths") {
                if let service = backendService(KubeList.dict(path, "backend")) { out.append((service, host)) }
            }
        }
        if let service = backendService(KubeList.dict(spec, "defaultBackend")) { out.append((service, "*")) }
        return out
    }

    private static func backendService(_ backend: [String: Any]) -> String? {
        KubeList.string(KubeList.dict(backend, "service"), "name")
    }
}
