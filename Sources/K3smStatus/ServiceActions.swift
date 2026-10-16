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

/// ServiceAction is a change the console can make to one Service: a single
/// fixed kubectl argument list, asked for behind a confirmation and
/// reported in one line.
public enum ServiceAction: String, Sendable, CaseIterable, Identifiable {
    case delete

    public var id: Self { self }

    /// The button's title.
    public var title: String {
        switch self {
        case .delete: return "Delete"
        }
    }
}

/// ServiceActionRequest is one action on one Service, fixed when the user
/// asks for it: the names and UID come from the Service as it was listed
/// then, and a Service recreated under the same name since is refused by
/// its UID.
public struct ServiceActionRequest: Equatable, ConsoleActionRequest {
    public let action: ServiceAction
    public let namespace: ResourceName
    public let service: ResourceName
    /// The Service's selection key, "namespace/name".
    public let serviceKey: String
    /// The Service's UID as listed when the action was asked for.
    public let uid: String
    /// The Ingress hosts routing to it when it was listed, clipped.
    public let hosts: [String]

    public var id: String { "\(action.rawValue):\(serviceKey)" }
    public var section: ConsoleSection { .services }
    public var rowKey: String { serviceKey }
    public var verb: String { "service-\(action.rawValue)" }
    public var kind: ActionKind {
        switch action {
        case .delete: return .delete
        }
    }

    /// The read run just before the action, whose output must be `uid`.
    public var precheckArguments: [String]? {
        K3smCLI.serviceUIDArguments(namespace: namespace, service: service)
    }

    public var arguments: [String] {
        switch action {
        case .delete: return K3smCLI.deleteServiceArguments(namespace: namespace, service: service)
        }
    }

    public var confirmation: ActionConfirmation {
        switch action {
        case .delete:
            var message = "k3sm deletes this Service: its cluster IP and any node ports are released, and clients "
                + "that reach it by name or address stop connecting. Its pods keep running."
            if !hosts.isEmpty {
                message += " The Ingress hosts that route to it (\(hosts.joined(separator: ", "))) stop answering."
            }
            return ActionConfirmation(
                title: "Delete service \(StatusDisplay.clip(namespace.value + "/" + service.value))?",
                message: message, verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        }
    }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        ServiceActions.verify(self, run: run)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        ServiceActions.report(self, run: run)
    }
}

/// ServiceActions decides what a Service row offers: copies of its cluster
/// IP and DNS name, Open in browser and Copy URL when it has a web address
/// (`browserURL`), and Delete; builds the requests and reports their runs.
public enum ServiceActions {
    /// The cluster's DNS domain, as the Service names resolve in pods.
    public static let clusterDomain = "cluster.local"
    /// The port names that mark a node port as a web port.
    public static let webPortNames: Set<String> = ["http", "https"]
    /// The port numbers that mark a node port as a web port.
    public static let webPortNumbers: Set<Int> = [80, 443, 8080]
    /// The address a node port answers on from this Mac: every node serves
    /// its node ports on its loopback as on its LAN address.
    public static let nodePortHost = "127.0.0.1"

    /// Whether the console refuses every change to a Service: the API
    /// server's own (`default/kubernetes`) and every Service in
    /// `kube-system`, which the cluster runs on. Such a row offers only its
    /// copies.
    public static func refuses(namespace: String, name: String) -> Bool {
        namespace == "kube-system" || (namespace == "default" && name == "kubernetes")
    }

    /// The row's actions as its context menu, the inspector and the Delete
    /// key show them: the copies, then Open in browser and Copy URL, then
    /// Delete. A refused Service (`refuses`) gets the copies alone; a name
    /// `ResourceName` refuses gets no DNS copy and no Delete.
    public static func menu(for row: ServiceRow) -> ActionMenu {
        var local: [LocalMenuItem] = []
        if let ip = clusterIP(row) {
            local.append(LocalMenuItem(id: "copy-ip", title: "Copy Cluster IP", action: .copy(ip)))
        }
        if let dns = dnsName(row) {
            local.append(LocalMenuItem(id: "copy-dns", title: "Copy DNS Name", action: .copy(dns)))
        }
        guard !refuses(namespace: row.namespace, name: row.name) else { return ActionMenu([], local: local) }
        if let url = browserURL(for: row) {
            local.append(LocalMenuItem(id: "open", title: "Open in Browser", action: .open(url)))
            local.append(LocalMenuItem(id: "copy-url", title: "Copy URL", action: .copy(url.absoluteString)))
        }
        return ActionMenu(ServiceAction.allCases.compactMap { request($0, for: row) }, local: local)
    }

    /// The request for one action on a Service, or nil when it does not
    /// offer it: a refused Service, a name `ResourceName` refuses, or a
    /// Service listed without a UID.
    public static func request(_ action: ServiceAction, for row: ServiceRow) -> ServiceActionRequest? {
        guard !refuses(namespace: row.namespace, name: row.name), !row.uid.isEmpty,
              let namespace = ResourceName(row.namespace), let service = ResourceName(row.name) else { return nil }
        return ServiceActionRequest(action: action, namespace: namespace, service: service, serviceKey: row.key, uid: row.uid, hosts: row.hosts)
    }

    /// The cluster IP to copy: nil for a headless Service ("None"), one with
    /// none, or a value that is not an IPv4 or IPv6 address.
    public static func clusterIP(_ row: ServiceRow) -> String? {
        let ip = row.clusterIP
        guard !ip.isEmpty, ip != "None", ip.count <= 45 else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        guard ip.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return ip
    }

    /// The Service's DNS name, `<name>.<namespace>.svc.cluster.local`; nil
    /// when either name is not one `ResourceName` accepts.
    public static func dnsName(_ row: ServiceRow) -> String? {
        guard let namespace = ResourceName(row.namespace), let name = ResourceName(row.name) else { return nil }
        return "\(name.value).\(namespace.value).svc.\(clusterDomain)"
    }

    /// The address Open in browser opens, or nil when the Service has none.
    /// An Ingress host comes first, the first in sorted order that is a
    /// whole DNS name (not `*` or a wildcard), over https when an Ingress
    /// routing it lists it under TLS and http otherwise. Without one, the
    /// first TCP port with a node port that is named http or https or
    /// numbered 80, 443 or 8080 opens `http://127.0.0.1:<nodePort>`, or
    /// https for a port named https or numbered 443.
    public static func browserURL(for row: ServiceRow) -> URL? {
        if let host = row.hosts.first(where: { ResourceName($0) != nil }) {
            return url(scheme: row.tlsHosts.contains(host) ? "https" : "http", host: host, port: nil)
        }
        for port in row.servicePorts where port.proto == "TCP" {
            guard let nodePort = port.nodePort, (1...65535).contains(nodePort) else { continue }
            let named = port.name.map(webPortNames.contains) ?? false
            guard named || webPortNumbers.contains(port.port) else { continue }
            let secure = port.name == "https" || (port.name != "http" && port.port == 443)
            return url(scheme: secure ? "https" : "http", host: nodePortHost, port: nodePort)
        }
        return nil
    }

    private static func url(scheme: String, host: String, port: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url
    }

    /// What the UID read just before the action says: nil when the Service
    /// is still the one confirmed, so the action runs; otherwise the line
    /// shown instead, and nothing runs.
    public static func verify(_ request: ServiceActionRequest, run: ActionRun) -> ActionOutcome? {
        let verb = request.action.title
        let changed = ActionOutcome.refused("\(verb) refused: the service changed since you clicked; nothing was deleted.")
        switch run {
        case .exited(status: 0, let output):
            let read = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return read == request.uid ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; nothing was deleted. " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the service check; nothing was deleted.")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: ServiceActionRequest, run: ActionRun) -> ActionOutcome {
        let verb = request.action.title
        switch run {
        case .exited(status: 0, _):
            switch request.action {
            case .delete:
                return .succeeded("\(verb) asked: the service \(StatusDisplay.clip(request.serviceKey)) is being removed.")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)" : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the service was deleted.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
