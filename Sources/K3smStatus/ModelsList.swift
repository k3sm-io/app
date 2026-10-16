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

/// ModelRow is one MLXModel as the Models tab lists it. Every string is clipped.
public struct ModelRow: Equatable, Sendable {
    /// "namespace/name", unique per row.
    public let key: String
    public let namespace: String
    public let name: String
    /// The model the spec serves (`spec.model`), "" when unset.
    public let model: String
    /// The controller's phase (`status.phase`), "" before it reports one.
    public let phase: String
    /// Ready replicas of the replicas asked for (`spec.replicas`, 1 when unset).
    public let readyReplicas: Int
    public let replicas: Int
    /// The served endpoint (`status.endpoint`), nil before it is set.
    public let endpoint: String?

    /// "1/2", ready of asked for.
    public var replicasText: String { "\(readyReplicas)/\(replicas)" }

    /// The severity word the row colours its dot by, as `PodHealth`.
    public var severity: String {
        switch phase {
        case "Ready": return "ok"
        case "Failed": return "bad"
        case "": return "off"
        default: return "warn"
        }
    }
}

/// ModelsList decodes `K3smCLI.modelsArguments`, the cluster's MLXModels,
/// and decides whether a failed read is a failure or the API being absent.
/// The MLX API is a CRD k3sm installs; on a cluster without it the list
/// fails like any other kubectl error, so a failed read is followed by a
/// discovery read (`K3smCLI.modelsDiscoveryArguments`) and the tab is
/// unavailable, not failed, when discovery answers and does not name the
/// resource.
public enum ModelsList {
    /// The resource the tab reads, as `kubectl api-resources -o name` names it.
    public static let resource = "mlxmodels.mlx.k3sm.io"
    /// The tab's line when the cluster does not serve the MLX API.
    public static let unavailableText = "Unavailable (the MLX API is not served on this cluster)."
    /// The tab's line when the cluster has no MLXModel.
    public static let emptyText = "No models on the cluster. Apply an MLXModel and it appears here."

    /// The rows, sorted by namespace and name. It throws `KubeListError`
    /// when the bytes are not a list of MLXModels.
    public static func decode(_ data: Data) throws -> [ModelRow] {
        let rows = try KubeList.objects(data, kinds: ["MLXModel"]).map { object -> ModelRow in
            let namespace = KubeList.namespace(object)
            let name = KubeList.name(object)
            let spec = KubeList.dict(object, "spec")
            let status = KubeList.dict(object, "status")
            return ModelRow(
                key: StatusDisplay.clip("\(namespace)/\(name)"),
                namespace: StatusDisplay.clip(namespace),
                name: StatusDisplay.clip(name),
                model: StatusDisplay.clip(KubeList.string(spec, "model") ?? ""),
                phase: StatusDisplay.clip(KubeList.string(status, "phase") ?? ""),
                readyReplicas: max(0, KubeList.int(status, "readyReplicas") ?? 0),
                replicas: max(0, KubeList.int(spec, "replicas") ?? 1),
                endpoint: KubeList.string(status, "endpoint").map(StatusDisplay.clip))
        }
        return rows.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// Whether the list's run needs the discovery read before it can be
    /// classified: only a non-zero exit does.
    public static func needsDiscovery(listExit: Int32) -> Bool {
        listExit != 0
    }

    /// Whether a discovery run says the cluster serves the resource: true
    /// when a line names it, false when the run succeeded without naming
    /// it, nil when the run failed (nothing can be concluded).
    public static func served(discoveryExit: Int32, stdout: Data) -> Bool? {
        guard discoveryExit == 0 else { return nil }
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.contains { $0.trimmingCharacters(in: .whitespaces) == resource }
    }

    /// The tab result of a list run and, when the list failed, the
    /// discovery run that followed it: a decoded list is its rows; a failed
    /// list on a cluster that answers discovery without the resource is
    /// unavailable; any other failure is failed.
    public static func tabResult(
        listExit: Int32, listStdout: Data, discovery: (exit: Int32, stdout: Data)?
    ) -> TabResult<[ModelRow]> {
        guard needsDiscovery(listExit: listExit) else {
            return KubeList.tabResult(exitCode: listExit, stdout: listStdout, what: "model list", decode: decode)
        }
        if let discovery, served(discoveryExit: discovery.exit, stdout: discovery.stdout) == false {
            return .unavailable(unavailableText)
        }
        return .failed("k3sm kubectl exited \(listExit)")
    }

    /// The rows the search leaves visible: all for an empty query, else those
    /// whose namespace, name or model contains it, case ignored.
    public static func visible(_ rows: [ModelRow], query: String) -> [ModelRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            [row.namespace, row.name, row.model].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
