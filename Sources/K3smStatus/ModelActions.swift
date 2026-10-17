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

/// ModelScale is the replica change Unload or Load makes to one MLXModel:
/// Unload records the count it had and asks for none; Load asks for a
/// count again and drops the record.
public enum ModelScale: Equatable, Sendable {
    case unload(recording: Int)
    case load(to: Int)
}

/// ModelAction is a change the console can make to one MLXModel.
public enum ModelAction: String, Sendable, CaseIterable, Identifiable {
    /// Scales a serving model to zero replicas, keeping the object.
    case unload
    /// Scales an unloaded model back to its recorded count.
    case load
    /// Deletes the model.
    case delete

    public var id: Self { self }

    public var title: String {
        switch self {
        case .unload: return "Unload"
        case .load: return "Load"
        case .delete: return "Delete"
        }
    }
}

/// ModelActionRequest is one action on one model, fixed when the user asks
/// for it: the names, UID and replica change come from the model as it was
/// listed then, and a model recreated under the same name since is refused
/// by its UID.
public struct ModelActionRequest: Equatable, ConsoleActionRequest {
    public let action: ModelAction
    public let namespace: ResourceName
    public let model: ResourceName
    /// The model's selection key, "namespace/name".
    public let modelKey: String
    /// The model's UID as listed when the action was asked for.
    public let uid: String
    /// The replica change, for Unload and Load; nil for Delete.
    public let scale: ModelScale?
    /// Whether the model has a weights cache volume.
    public let hasCache: Bool
    /// The CLI arguments, fixed with the request.
    public let arguments: [String]

    public var id: String { "\(action.rawValue):\(modelKey)" }
    public var section: ConsoleSection { .models }
    public var rowKey: String { modelKey }
    public var verb: String { "model-\(action.rawValue)" }
    /// Only Delete removes the row; Unload and Load change it.
    public var kind: ActionKind { action == .delete ? .delete : .change }

    /// Every model action reads the model's UID first (`ModelActions.verify`).
    public var precheckArguments: [String]? {
        K3smCLI.modelUIDArguments(namespace: namespace, model: model)
    }

    public func precheck(_ run: ActionRun) -> ActionOutcome? {
        ModelActions.verify(self, run: run)
    }

    public func report(_ run: ActionRun) -> ActionOutcome {
        ModelActions.report(self, run: run)
    }

    public var confirmation: ActionConfirmation {
        let title = "\(action.title) \(StatusDisplay.clip(namespace.value + "/" + model.value))?"
        switch (action, scale) {
        case (.unload, .unload(let count)?):
            return ActionConfirmation(
                title: title,
                message: "k3sm scales this model to zero: its \(ModelActions.replicas(count)) stop and its endpoint stops answering. "
                    + "The model stays, with the count recorded on it, and Load brings back \(ModelActions.replicas(count)).",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        case (.load, .load(let count)?):
            return ActionConfirmation(
                title: title,
                message: "k3sm scales this model back to \(ModelActions.replicas(count)). "
                    + "Each one loads the weights before it serves, so it can take a while to become ready.",
                verbTitle: action.title, cancelTitle: "Cancel", destructive: false)
        default:
            let message = hasCache
                ? "k3sm deletes this model, its serving pods, its Services and its cache claim. "
                    + "The weights volume is kept: it appears in the Storage tab as Released, and deleting it there removes only the object, the data stays on the node's disk."
                : "k3sm deletes this model, its serving pods and its Services. It has no cache volume, so no weights are kept."
            return ActionConfirmation(
                title: title,
                message: message,
                verbTitle: action.title, cancelTitle: "Cancel", destructive: true)
        }
    }
}

/// ModelActions decides which actions an MLXModel offers, builds their
/// requests and patches, and reports their runs. The MLX API has no load
/// verb and no scale subresource, so Unload and Load are merge patches of
/// `spec.replicas`, with the count Unload replaced kept in an annotation on
/// the model itself.
public enum ModelActions {
    /// The annotation Unload records the replica count in, and Load reads
    /// and removes.
    public static let replicasAnnotation = "k3sm.io/replicas-before-unload"

    /// The replica change a model offers, decided only by its spec's
    /// replicas and the recorded count: a model asking for replicas offers
    /// Unload, which records that count; a model asking for none offers
    /// Load, back to the recorded count (`restoreCount`).
    public static func scale(replicas: Int, recorded: String?) -> ModelScale {
        replicas > 0 ? .unload(recording: replicas) : .load(to: restoreCount(recorded))
    }

    /// The count Load restores: the recorded annotation when it is a whole
    /// number from 1 to the CRD's int32 ceiling, written in plain digits;
    /// 1 when it is absent or anything else.
    public static func restoreCount(_ recorded: String?) -> Int {
        readableCount(recorded) ?? 1
    }

    /// The recorded count when it is readable (plain digits from 1 to the
    /// int32 ceiling), nil when it is absent or anything else: the case
    /// where `restoreCount` falls back to 1.
    public static func readableCount(_ recorded: String?) -> Int? {
        guard let recorded, !recorded.isEmpty, recorded.count <= 10,
              recorded.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let count = Int(recorded), count >= 1, count <= Int(Int32.max) else { return nil }
        return count
    }

    /// The merge patch for a replica change, serialised from typed values
    /// with sorted keys: Unload sets the annotation to the recorded count
    /// (annotation values are strings) and `spec.replicas` to 0; Load sets
    /// `spec.replicas` to its count and the annotation to null, which a
    /// merge patch removes.
    public static func patch(_ scale: ModelScale) -> String? {
        let annotation: Any
        let replicas: Int
        switch scale {
        case .unload(let count):
            annotation = String(count)
            replicas = 0
        case .load(let count):
            annotation = NSNull()
            replicas = count
        }
        let object: [String: Any] = [
            "metadata": ["annotations": [replicasAnnotation: annotation]],
            "spec": ["replicas": replicas],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The actions offered for a model, in button order: Unload or Load
    /// (never both, `scale`), then Delete; nothing for a model whose name or
    /// namespace `ResourceName` refuses or that was listed without a UID.
    public static func available(for row: ModelRow) -> [ModelAction] {
        ModelAction.allCases.filter { request($0, for: row) != nil }
    }

    /// The model's actions as its context menu, the inspector and the Delete
    /// key show them: the copies first, then the requests.
    public static func menu(for row: ModelRow) -> ActionMenu {
        ActionMenu(available(for: row).compactMap { request($0, for: row) }, local: local(for: row))
    }

    /// The request for one action on a model, or nil when it does not offer it.
    public static func request(_ action: ModelAction, for row: ModelRow) -> ModelActionRequest? {
        guard let namespace = row.namespaceName, let model = row.resourceName, !row.uid.isEmpty else { return nil }
        let scale = scale(replicas: row.replicas, recorded: row.replicasBeforeUnload)
        let arguments: [String]
        switch (action, scale) {
        case (.unload, .unload), (.load, .load):
            guard let argv = K3smCLI.modelScaleArguments(namespace: namespace, model: model, scale: scale) else { return nil }
            arguments = argv
        case (.unload, .load), (.load, .unload):
            return nil
        case (.delete, _):
            arguments = K3smCLI.deleteModelArguments(namespace: namespace, model: model)
        }
        return ModelActionRequest(
            action: action, namespace: namespace, model: model, modelKey: row.key, uid: row.uid,
            scale: action == .delete ? nil : scale, hasCache: row.hasCache, arguments: arguments)
    }

    /// The copies a model offers: its endpoint, when it has one written in
    /// address characters only, and a curl example when `curlExample` can
    /// build one.
    public static func local(for row: ModelRow) -> [LocalMenuItem] {
        var items: [LocalMenuItem] = []
        if let endpoint = row.endpoint, isAddress(endpoint) {
            items.append(LocalMenuItem(id: "copy-endpoint", title: "Copy Endpoint", action: .copy(endpoint)))
        }
        if let curl = curlExample(for: row) {
            items.append(LocalMenuItem(id: "copy-curl", title: "Copy curl Example", action: .copy(curl)))
        }
        return items
    }

    /// The port of the model's own Service in its published endpoint:
    /// `status.endpoint` is `<name>.<namespace>.svc.<domain>:<port>` (the
    /// operator names the Service after the model), with or without an
    /// http:// prefix. Nil for an endpoint that names any other host.
    static func servicePort(for row: ModelRow) -> Int? {
        guard let endpoint = row.endpoint, let name = row.resourceName, let namespace = row.namespaceName else { return nil }
        var rest = Substring(endpoint)
        if rest.hasPrefix("http://") { rest = rest.dropFirst("http://".count) }
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let host = rest[..<colon]
        let portText = rest[rest.index(after: colon)...]
        guard !portText.isEmpty, portText.count <= 5, portText.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        let service = "\(name.value).\(namespace.value).svc"
        guard host == service || (host.hasPrefix(service + ".") && ResourceName(String(host)) != nil) else { return nil }
        return port
    }

    /// A curl call of the model's chat completions API, as the MLX
    /// quickstart makes it from the Mac: the Service's cluster IP, read by
    /// the installed CLI's kubectl inside the command, the port from the
    /// published endpoint, and a JSON body naming the served model. Nil
    /// while the model publishes no endpoint of its own Service, or when its
    /// model is not a plain repository id, since the text is pasted into a
    /// shell.
    public static func curlExample(for row: ModelRow) -> String? {
        guard let port = servicePort(for: row), let name = row.resourceName, let namespace = row.namespaceName,
              isRepositoryID(row.model) else { return nil }
        let body: [String: Any] = [
            "model": row.model,
            "messages": [["role": "user", "content": "Hello"]],
            "max_tokens": 64,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        let json = String(decoding: data, as: UTF8.self)
        let vip = "$(\(K3smCLI.path) kubectl get svc \(name.value) -n \(namespace.value) -o jsonpath='{.spec.clusterIP}')"
        return "curl -sS \"http://\(vip):\(port)/v1/chat/completions\" -H 'Content-Type: application/json' -d '\(json)'"
    }

    /// Whether text is a model repository id the curl body may carry: ASCII
    /// letters, digits and . _ / -, nothing that could close a shell quote.
    static func isRepositoryID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text.unicodeScalars.allSatisfy { s in
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || "._/-".unicodeScalars.contains(s)
        }
    }

    /// Whether text is written only in the characters of a host, port and
    /// path, so a copy carries nothing else.
    static func isAddress(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { s in
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || ".:/-_[]".unicodeScalars.contains(s)
        }
    }

    /// "1 replica", "2 replicas".
    static func replicas(_ count: Int) -> String {
        count == 1 ? "1 replica" : "\(count) replicas"
    }

    /// What nothing happened means for an action: "changed" or "deleted".
    private static func untouched(_ action: ModelAction) -> String {
        action == .delete ? "nothing was deleted" : "nothing was changed"
    }

    /// What the UID read just before the action says: nil when the model is
    /// still the one confirmed, so the action runs; otherwise the line shown
    /// instead, and nothing runs.
    public static func verify(_ request: ModelActionRequest, run: ActionRun) -> ActionOutcome? {
        let verb = request.action.title
        let nothing = untouched(request.action)
        let changed = ActionOutcome.refused("\(verb) refused: the model changed since you clicked; \(nothing).")
        switch run {
        case .exited(status: 0, let output):
            let read = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return read == request.uid ? nil : changed
        case .exited(let status, let output):
            let raw = String(decoding: output, as: UTF8.self)
            if raw.contains("(NotFound)") { return changed }
            let text = StatusDisplay.errorText(raw)
            return .failed("\(verb) failed; \(nothing). " + (text.isEmpty ? "k3sm kubectl exited \(status)" : "kubectl said: \(text)"))
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer the model check; \(nothing).")
        case .missing, .refused:
            return report(request, run: run)
        }
    }

    /// The line shown after a run. CLI text passes `StatusDisplay.errorText`.
    public static func report(_ request: ModelActionRequest, run: ActionRun) -> ActionOutcome {
        let verb = request.action.title
        switch run {
        case .exited(status: 0, _):
            switch (request.action, request.scale) {
            case (.unload, .unload(let count)?):
                return .succeeded("Unload asked: the operator scales the model to zero, and Load brings back \(replicas(count)).")
            case (.load, .load(let count)?):
                return .succeeded("Load asked: the operator scales the model to \(replicas(count)).")
            default:
                return .succeeded(request.hasCache
                    ? "Delete asked: k3sm removes the model; its weights volume stays in the Storage tab."
                    : "Delete asked: k3sm removes the model.")
            }
        case .exited(let status, let output):
            let text = StatusDisplay.errorText(String(decoding: output, as: UTF8.self))
            return .failed(text.isEmpty ? "\(verb) failed: k3sm kubectl exited \(status)" : "\(verb) failed. kubectl said: \(text)")
        case .noAnswer:
            return .failed("\(verb) failed: the k3sm CLI did not answer. Refresh to see whether the model changed.")
        case .missing:
            return .failed("\(verb) failed: k3sm is not installed on this Mac.")
        case .refused(let why):
            return .failed("\(verb) failed: the installed k3sm failed the app's check (\(StatusDisplay.errorText(why))), so it was not run.")
        }
    }
}
