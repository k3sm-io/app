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

/// InspectorFact is one label and value of the inspector's facts grid. The
/// value is decoder output, already clipped; `mono` sets it in the
/// monospaced face (references, digests, addresses).
public struct InspectorFact: Equatable, Sendable {
    public let label: String
    public let value: String
    public let mono: Bool

    public init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }
}

/// InspectorBody is the inspector's content for one selected row: its
/// header (the kind and the row's name, with the namespace under it when
/// the row has one) and its facts, in order.
public struct InspectorBody: Equatable, Sendable {
    /// The kind, capitalised, as the header names it ("Image", "Service").
    public let kind: String
    public let title: String
    public let subtitle: String?
    public let facts: [InspectorFact]
}

/// InspectorDetails is the inspector's text for every tab but Workloads
/// (whose pod inspector is its own view): what each kind of row shows,
/// built only from the row types the tabs already decode, and the line the
/// inspector shows when its tab has no selection. Nothing is invented: a
/// fact the read did not carry is left out or says it was not reported.
public enum InspectorDetails {
    /// The Builds tab's one selectable row today, the engine card. The build
    /// history's rows will take their own keys beside it.
    public static let engineRow = "engine"

    /// What a row of each tab is called, lowercase.
    public static func kind(of section: ConsoleSection) -> String {
        switch section {
        case .workloads: return "pod"
        case .images: return "image"
        case .builds: return "build"
        case .services: return "service"
        case .storage: return "claim"
        case .models: return "model"
        }
    }

    /// The inspector's line while its tab has no selection: "Select an image."
    public static func emptyText(_ section: ConsoleSection) -> String {
        let kind = kind(of: section)
        let article = "aeiou".contains(kind.first ?? "x") ? "an" : "a"
        return "Select \(article) \(kind)."
    }

    /// The keys a tab's read lists, for `ConsoleSelection`: nil while the
    /// tab has nothing decoded, so a selection waits for a read.
    public static func keys(images: ImagesReading?) -> Set<String>? {
        switch images {
        case nil: return nil
        case .notReported?: return []
        case .listed(let images)?: return Set(images.map(\.key))
        }
    }

    /// An image: the name it shows, its digest, size, the nodes holding it,
    /// its other names, and, when the pod list has been read, the pods whose
    /// image is one of its names or carries its digest.
    public static func image(_ image: NodeImage, pods: [Pod]?) -> InspectorBody {
        var facts = [InspectorFact("Reference", image.title, mono: true)]
        facts.append(InspectorFact("Digest", image.digest ?? "not reported", mono: true))
        facts.append(InspectorFact("Size", sized(image.sizeBytes)))
        facts.append(InspectorFact("Nodes", image.nodes.isEmpty ? "none" : image.nodes.joined(separator: ", ")))
        let others = image.names.filter { $0 != image.title }
        if !others.isEmpty {
            facts.append(InspectorFact("Also named", others.joined(separator: ", "), mono: true))
        }
        if let pods {
            let using = podsUsing(image, in: pods).map { StatusDisplay.clip("\($0.namespace)/\($0.name)") }
            facts.append(InspectorFact("Used by", using.isEmpty ? "no listed pod" : using.joined(separator: ", ")))
        }
        return InspectorBody(kind: "Image", title: image.title, subtitle: nil, facts: facts)
    }

    /// The build engine, the Builds tab's card: its state and why, its pod
    /// and node, and its cache claim.
    public static func build(_ engine: BuildEngine) -> InspectorBody {
        var facts = [InspectorFact("State", engine.state.word), InspectorFact("Detail", engine.state.detail)]
        facts.append(InspectorFact("Pod", engine.podName ?? "none"))
        if let node = engine.nodeName { facts.append(InspectorFact("Node", node)) }
        if let cache = engine.cache {
            facts.append(InspectorFact("Cache", cache.name))
            if !cache.phase.isEmpty { facts.append(InspectorFact("Cache phase", cache.phase)) }
            facts.append(InspectorFact("Cache size", sized(cache.capacityBytes)))
        } else {
            facts.append(InspectorFact("Cache", "none"))
        }
        return InspectorBody(kind: "Build engine", title: engine.podName ?? BuildEngine.defaultName, subtitle: nil, facts: facts)
    }

    /// A Service: its type, cluster IP, each port, its ready endpoints, and
    /// the Ingress hosts that route to it.
    public static func service(_ row: ServiceRow) -> InspectorBody {
        var facts = [InspectorFact("Type", row.type)]
        facts.append(InspectorFact("Cluster IP", row.clusterIP.isEmpty ? "none" : row.clusterIP, mono: true))
        facts.append(InspectorFact("Ports", row.ports.isEmpty ? "none" : row.ports.joined(separator: ", "), mono: true))
        facts.append(InspectorFact("Endpoints", endpointsText(row)))
        facts.append(InspectorFact("Ingress hosts", row.hosts.isEmpty ? "none" : row.hosts.joined(separator: ", ")))
        return InspectorBody(kind: "Service", title: row.name, subtitle: row.namespace, facts: facts)
    }

    /// A Service's ready endpoints: "2 ready", "none ready", "not reported"
    /// before the EndpointSlices are read, and "not used" for an
    /// ExternalName Service, which has none by design.
    static func endpointsText(_ row: ServiceRow) -> String {
        if row.type == "ExternalName" { return "not used (ExternalName)" }
        guard let count = row.endpoints else { return "not reported" }
        return count == 0 ? "none ready" : "\(count) ready"
    }

    /// A claim (or a volume no claim holds): the bound volume, capacity,
    /// access modes, class and phase.
    public static func claim(_ row: StorageRow) -> InspectorBody {
        var facts: [InspectorFact] = []
        if row.claim != nil {
            facts.append(InspectorFact("Volume", row.volume ?? "not bound", mono: true))
        } else {
            facts.append(InspectorFact("Claim", "none holds it"))
        }
        facts.append(InspectorFact("Capacity", sized(row.capacityBytes)))
        facts.append(InspectorFact("Access", row.accessModes.isEmpty ? "not reported" : row.accessModes.joined(separator: ", ")))
        facts.append(InspectorFact("Class", row.storageClass ?? "none"))
        facts.append(InspectorFact("Phase", row.phase.isEmpty ? "not reported" : row.phase))
        if let claim = row.claim {
            return InspectorBody(kind: "Claim", title: claim, subtitle: row.namespace, facts: facts)
        }
        return InspectorBody(kind: "Volume", title: row.volume ?? row.key, subtitle: nil, facts: facts)
    }

    /// An MLXModel: the model its spec serves, the replicas asked for and
    /// ready, its phase and endpoint.
    public static func model(_ row: ModelRow) -> InspectorBody {
        let facts = [
            InspectorFact("Model", row.model.isEmpty ? "not set" : row.model, mono: true),
            InspectorFact("Replicas", String(row.replicas)),
            InspectorFact("Ready", String(row.readyReplicas)),
            InspectorFact("Phase", row.phase.isEmpty ? "not reported" : row.phase),
            InspectorFact("Endpoint", row.endpoint ?? "not set", mono: true),
        ]
        return InspectorBody(kind: "Model", title: row.name, subtitle: row.namespace, facts: facts)
    }

    /// The pods whose image (the pod list decodes its first container's) is
    /// one of the image's names, compared in their normalised form, or names
    /// its digest.
    static func podsUsing(_ image: NodeImage, in pods: [Pod]) -> [Pod] {
        let names = Set(image.names.map(normalized))
        return pods.filter { pod in
            guard !pod.image.isEmpty else { return false }
            if let digest = image.digest, ImagesList.digest(of: pod.image) == digest { return true }
            return names.contains(normalized(pod.image))
        }
    }

    /// A reference in its fully qualified form, the way a kubelet reports
    /// it: a first path part with no "." or ":" that is not "localhost" is a
    /// Docker Hub path (official images under "library/"), and a reference
    /// with neither tag nor digest is ":latest". These are the rules of the
    /// distribution reference library's normalised names, written here.
    static func normalized(_ reference: String) -> String {
        var name = reference
        var digest = ""
        if let at = reference.firstIndex(of: "@") {
            name = String(reference[..<at])
            digest = String(reference[at...])
        }
        var domain = "docker.io"
        var path = name
        if let slash = name.firstIndex(of: "/") {
            let first = name[..<slash]
            if first.contains(".") || first.contains(":") || first == "localhost" {
                domain = String(first)
                path = String(name[name.index(after: slash)...])
            }
        }
        if domain == "index.docker.io" { domain = "docker.io" }
        if domain == "docker.io", !path.contains("/") { path = "library/" + path }
        let last = path.split(separator: "/").last ?? ""
        if digest.isEmpty, !last.contains(":") { path += ":latest" }
        return domain + "/" + path + digest
    }

    private static func sized(_ bytes: Int64?) -> String {
        let text = WorkloadsDisplay.bytes(bytes)
        return text.isEmpty ? "not reported" : text
    }
}
