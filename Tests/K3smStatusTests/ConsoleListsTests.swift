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
import Testing

@testable import K3smStatus

@Suite("the Services tab")
struct ServicesListTests {
    @Test("services decode with their type, cluster IP, ports and ingress hosts")
    func decodesServicesWithIngressHosts() throws {
        let rows = try ServicesList.decode(try fixture("kubectl_services_ingress.json"))
        #expect(rows.map(\.key) == ["default/kubernetes", "shop/db", "shop/web"])
        let web = try #require(rows.last)
        #expect(web.type == "NodePort")
        #expect(web.clusterIP == "10.43.0.20")
        #expect(web.ports == ["80:30080/TCP", "443/TCP"])
        // A rule without a host is "*"; another namespace's Ingress never attaches.
        #expect(web.hosts == ["*", "shop.example.test"])
        let db = rows[1]
        #expect(db.type == "ClusterIP")
        #expect(db.clusterIP == "None")
        #expect(db.hostsText == "-")
        #expect(rows[0].portsText == "443/TCP")
    }

    @Test("a default backend routes every host")
    func defaultBackendIsAnyHost() throws {
        let data = Data(#"{"kind":"List","items":[{"kind":"Service","metadata":{"name":"s","namespace":"n"},"spec":{}},{"kind":"Ingress","metadata":{"name":"i","namespace":"n"},"spec":{"defaultBackend":{"service":{"name":"s"}}}}]}"#.utf8)
        #expect(try ServicesList.decode(data).first?.hosts == ["*"])
    }

    @Test("a list of another kind fails the read")
    func otherKindFails() throws {
        let result = ServicesList.tabResult(exitCode: 0, stdout: try fixture("kubectl_pods_running.json"))
        guard case .failed(let text) = result else { Issue.record("want failed, got \(result)"); return }
        #expect(text.contains("not the service list"))
        #expect(ServicesList.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm kubectl exited 1"))
        #expect(ServicesList.tabResult(exitCode: 0, stdout: Data("not json".utf8)) == .failed("the service list could not be read"))
    }

    @Test("a name that carries control characters is clipped to one line")
    func namesAreClipped() throws {
        let data = Data(#"{"kind":"List","items":[{"kind":"Service","metadata":{"name":"a\nb‮","namespace":"n"},"spec":{"type":"X\u0007"}}]}"#.utf8)
        let row = try #require(try ServicesList.decode(data).first)
        #expect(row.name == "a b")
        #expect(row.type == "X ")
    }

    @Test("the search matches a namespace, a name or a host")
    func search() throws {
        let rows = try ServicesList.decode(try fixture("kubectl_services_ingress.json"))
        #expect(ServicesList.visible(rows, query: "").count == 3)
        #expect(ServicesList.visible(rows, query: "SHOP.example").map(\.name) == ["web"])
        #expect(ServicesList.visible(rows, query: "kube").map(\.name) == ["kubernetes"])
    }
}

@Suite("the Storage tab")
struct StorageListTests {
    @Test("claims decode with their volumes, capacity and phase; volumes no claim holds follow")
    func decodesClaimsAndVolumes() throws {
        let rows = try StorageList.decode(try fixture("kubectl_storage.json"))
        #expect(rows.map(\.key) == ["pvc/build/cache", "pvc/shop/data-db-0", "pvc/shop/logs", "pv/pvc-9999"])
        // Unbound: no volume, the capacity it requests.
        #expect(rows[0].volume == nil)
        #expect(rows[0].capacityBytes == 512 << 20)
        #expect(rows[0].phase == "Pending")
        // The claim's own capacity wins over its request.
        #expect(rows[1].volume == "pvc-1111")
        #expect(rows[1].capacityBytes == 2 << 30)
        #expect(rows[1].storageClass == "local-path")
        // No capacity on the claim: the bound volume's.
        #expect(rows[2].capacityBytes == 4 << 30)
        // A released volume whose claim is gone is a row of its own.
        #expect(rows[3].claim == nil)
        #expect(rows[3].namespace == nil)
        #expect(rows[3].phase == "Released")
        #expect(rows[3].capacityBytes == 8 << 30)
    }

    @Test("a list of another kind fails the read")
    func otherKindFails() throws {
        let result = StorageList.tabResult(exitCode: 0, stdout: try fixture("kubectl_services_ingress.json"))
        guard case .failed(let text) = result else { Issue.record("want failed, got \(result)"); return }
        #expect(text.contains("not the volume claim list"))
    }

    @Test("the search matches a namespace, a claim or a volume")
    func search() throws {
        let rows = try StorageList.decode(try fixture("kubectl_storage.json"))
        #expect(StorageList.visible(rows, query: "9999").map(\.key) == ["pv/pvc-9999"])
        #expect(StorageList.visible(rows, query: "SHOP").count == 2)
    }
}

@Suite("the data volume card")
struct DataVolumeTests {
    @Test("a mounted volume decodes its record, capacity and the pre-volume copy")
    func mounted() throws {
        let v = try DataVolume.decode(try fixture("datavol_status_json_mounted.json"))
        #expect(v.recorded && v.mounted)
        #expect(v.word == "Mounted")
        #expect(v.severity == "ok")
        #expect(v.name == "k3sm")
        #expect(v.mountpoint == "/var/lib/k3sm")
        #expect(v.quotaBytes == 100 << 30)
        #expect(v.usedBytes == 35 << 30)
        #expect(v.preVolumeBytes == 4096)
        let labels = v.facts.map(\.0)
        #expect(labels == ["Volume", "Mount", "Quota", "Used", "Free", "Encrypted", "Old copy"])
        #expect(v.facts[3].1 == "35 GB of 100 GB")
    }

    @Test("a recorded volume that is not mounted is the bad state; a zero quota is none")
    func notMounted() throws {
        let v = try DataVolume.decode(try fixture("datavol_status_json_not-mounted.json"))
        #expect(v.word == "Not mounted")
        #expect(v.severity == "bad")
        #expect(v.facts.first { $0.0 == "Quota" }?.1 == "none")
        #expect(v.facts.first { $0.0 == "Encrypted" }?.1 == "yes")
        #expect(!v.facts.contains { $0.0 == "Used" || $0.0 == "Old copy" })
    }

    @Test("no record is a plain directory, not a failure")
    func noRecord() throws {
        let v = try DataVolume.decode(try fixture("datavol_status_json_no-record.json"))
        #expect(!v.recorded)
        #expect(v.word == "None")
        #expect(v.severity == "off")
        #expect(v.facts.isEmpty)
    }

    @Test("a usage k3sm cannot attribute is not shown")
    func unknownUsageIsHidden() throws {
        let data = Data(#"{"record":{"name":"k3sm"},"mounted":true,"statfs":{"totalBytes":10,"availBytes":5,"usedBytes":5,"usedSource":"unknown"},"preVolume":{}}"#.utf8)
        #expect(try DataVolume.decode(data).usedBytes == nil)
    }

    @Test("a failed or unreadable run fails the card")
    func failures() {
        #expect(DataVolume.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm datavol status exited 1"))
        #expect(DataVolume.tabResult(exitCode: 0, stdout: Data("[]".utf8)) == .failed("the data volume report could not be read"))
    }
}

@Suite("the Models tab")
struct ModelsListTests {
    @Test("models decode with their model, phase, replicas and endpoint")
    func decodesModels() throws {
        let rows = try ModelsList.decode(try fixture("kubectl_mlxmodels.json"))
        #expect(rows.map(\.key) == ["mlx/llama", "mlx/qwen"])
        #expect(rows[0].replicasText == "0/1")
        #expect(rows[0].severity == "warn")
        #expect(rows[0].endpoint == nil)
        #expect(rows[1].model == "mlx-community/Qwen3-4B-4bit")
        #expect(rows[1].replicasText == "2/2")
        #expect(rows[1].severity == "ok")
        #expect(rows[1].endpoint == "http://qwen.mlx.svc:8080")
    }

    @Test("a cluster without the MLX API is unavailable, not failed")
    func missingCRDIsUnavailableNotFailed() {
        // The list fails; discovery answers and does not name the resource.
        let none = ModelsList.tabResult(listExit: 1, listStdout: Data(), discovery: (0, Data()))
        #expect(none == .unavailable(ModelsList.unavailableText))
        let other = ModelsList.tabResult(listExit: 1, listStdout: Data(), discovery: (0, Data("mlxsomething.mlx.k3sm.io\n".utf8)))
        #expect(other == .unavailable(ModelsList.unavailableText))
        #expect(TabLoad.finished(none, at: Date()) == .unavailable(ModelsList.unavailableText))
    }

    @Test("a failed list on a cluster that serves the API, or with discovery failing too, is failed")
    func otherFailuresAreFailed() {
        let served = ModelsList.tabResult(listExit: 1, listStdout: Data(), discovery: (0, Data("mlxmodels.mlx.k3sm.io\n".utf8)))
        #expect(served == .failed("k3sm kubectl exited 1"))
        let unreachable = ModelsList.tabResult(listExit: 1, listStdout: Data(), discovery: (1, Data()))
        #expect(unreachable == .failed("k3sm kubectl exited 1"))
        #expect(ModelsList.tabResult(listExit: 1, listStdout: Data(), discovery: nil) == .failed("k3sm kubectl exited 1"))
    }

    @Test("discovery runs only after a failed list")
    func discoveryOnlyAfterFailure() throws {
        #expect(!ModelsList.needsDiscovery(listExit: 0))
        #expect(ModelsList.needsDiscovery(listExit: 1))
        let listed = ModelsList.tabResult(listExit: 0, listStdout: try fixture("kubectl_mlxmodels.json"), discovery: nil)
        guard case .value(let rows) = listed else { Issue.record("want rows, got \(listed)"); return }
        #expect(rows.count == 2)
        #expect(ModelsList.served(discoveryExit: 0, stdout: Data("  mlxmodels.mlx.k3sm.io  \n".utf8)) == true)
        #expect(ModelsList.served(discoveryExit: 2, stdout: Data()) == nil)
    }
}

@Suite("the Events view")
struct EventsListTests {
    @Test("events decode newest first, with the object and count")
    func decodesNewestFirst() throws {
        let events = try EventsList.decode(try fixture("kubectl_events.json"))
        #expect(events.map(\.key) == ["u-2", "u-3", "u-1"])
        #expect(events[0].object == "Pod web-1")
        #expect(events[0].count == 7)
        #expect(events[0].severity == "warn")
        // An eventTime with microseconds is read when lastTimestamp is null.
        #expect(events[1].time == KubeList.time("2026-10-15T10:02:30.123Z"))
        #expect(events[1].object == "Node mac-a")
        #expect(events[2].severity == "off")
    }

    static func event(_ i: Int, namespace: String, time: Date?) -> ClusterEvent {
        ClusterEvent(key: String(format: "e-%04d", i), namespace: namespace, type: "Normal", reason: "R",
                     message: "m", object: "Pod p", count: 1, time: time)
    }

    @Test("at most the cap is shown, the newest, and a timeless event comes last")
    func orderingAndCap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var events = (0..<250).map { Self.event($0, namespace: "busy", time: t0.addingTimeInterval(Double($0))) }
        events.append(Self.event(999, namespace: "busy", time: nil))
        let shown = EventsList.visible(events.shuffled(), namespace: nil)
        #expect(EventsList.cap == 200)
        #expect(shown.count == 200)
        #expect(shown.first?.key == "e-0249")
        #expect(shown.last?.key == "e-0050")
        #expect(!shown.contains { $0.time == nil })
        let few = EventsList.visible([Self.event(1, namespace: "a", time: nil), Self.event(2, namespace: "a", time: t0)], namespace: nil)
        #expect(few.map(\.key) == ["e-0002", "e-0001"])
    }

    @Test("the namespace filter applies before the cap")
    func filterBeforeCap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var events = (0..<300).map { Self.event($0, namespace: "busy", time: t0.addingTimeInterval(Double(1000 + $0))) }
        events.append(Self.event(500, namespace: "quiet", time: t0))
        #expect(EventsList.visible(events, namespace: "quiet").map(\.key) == ["e-0500"])
        #expect(!EventsList.visible(events, namespace: nil).contains { $0.namespace == "quiet" })
        #expect(EventsList.namespaces(events, selected: nil) == ["busy", "quiet"])
        #expect(EventsList.namespaces(events, selected: "gone") == ["busy", "gone", "quiet"])
        #expect(EventsList.emptyText(namespace: "gone") == "No events in gone.")
    }

    @Test("a list of another kind fails the read")
    func otherKindFails() throws {
        let result = EventsList.tabResult(exitCode: 0, stdout: try fixture("kubectl_storage.json"))
        guard case .failed(let text) = result else { Issue.record("want failed, got \(result)"); return }
        #expect(text.contains("not the event list"))
    }
}

@Suite("the panel's Interconnect card")
struct InterconnectCardTests {
    @Test("the vendored report's armed interconnect is a card")
    func armedIsShown() throws {
        let report = try StatusReport.decode(try fixture("status_json_running-interconnect.json"))
        let card = try #require(InterconnectCard.card(for: report))
        #expect(card.medium == "thunderbolt")
        #expect(card.nodes == "2 of 3 nodes up")
        #expect(card.segments == "1 segment")
        #expect(card.pods == "2 pods attached")
        #expect(card.warning == InterconnectCard.plaintextWarning)
        #expect(card.outOfRange == "Out of range: far")
    }

    @Test("no block, an unarmed one or a malformed one shows no card and never fails the report")
    func otherwiseHidden() throws {
        #expect(InterconnectCard.card(for: try StatusReport.decode(try fixture("status_json_running.json"))) == nil)
        #expect(InterconnectCard.card(for: nil) == nil)
        let unarmed = Data(#"{"schemaVersion":1,"verdict":"running","rows":[],"interconnect":{"name":"thunderbolt","armed":false,"members":2}}"#.utf8)
        #expect(InterconnectCard.card(for: try StatusReport.decode(unarmed)) == nil)
        let mistyped = Data(#"{"schemaVersion":1,"verdict":"running","rows":[],"interconnect":"yes"}"#.utf8)
        let report = try StatusReport.decode(mistyped)
        #expect(report.interconnect == nil)
        let stringArmed = Data(#"{"schemaVersion":1,"verdict":"running","rows":[],"interconnect":{"armed":"true"}}"#.utf8)
        #expect(InterconnectCard.card(for: try StatusReport.decode(stringArmed)) == nil)
    }
}

@Suite("the console's new tabs")
struct NewTabsTests {
    @Test("the new reads are fixed, read-only argument lists")
    func fixedReadOnlyArguments() {
        #expect(K3smCLI.servicesArguments == ["kubectl", "get", "svc,ingress", "-A", "-o", "json"])
        #expect(K3smCLI.storageArguments == ["kubectl", "get", "pvc,pv", "-A", "-o", "json"])
        #expect(K3smCLI.dataVolumeArguments == ["datavol", "status", "-o", "json"])
        #expect(K3smCLI.modelsArguments == ["kubectl", "get", "mlxmodels.mlx.k3sm.io", "-A", "-o", "json"])
        #expect(K3smCLI.modelsDiscoveryArguments == ["kubectl", "api-resources", "--api-group=mlx.k3sm.io", "-o", "name"])
        #expect(K3smCLI.eventsArguments == ["kubectl", "get", "events", "-A", "-o", "json"])
        for argv in [K3smCLI.servicesArguments, K3smCLI.storageArguments, K3smCLI.modelsArguments,
                     K3smCLI.modelsDiscoveryArguments, K3smCLI.eventsArguments] {
            #expect(argv.first == "kubectl")
            #expect(["get", "api-resources"].contains(argv[1]))
        }
    }

    @Test("the new tabs have their cadence and their order in the strip")
    func cadenceAndOrder() {
        #expect(ConsoleSection.allCases == [.workloads, .images, .builds, .services, .storage, .models])
        for section in [ConsoleSection.services, .storage, .models] {
            #expect(PollSchedule.interval(for: section, engineReady: false) == .seconds(15))
        }
        #expect(PollSchedule.eventsInterval == .seconds(5))
        #expect(ConsoleTabs.restore(from: "models") == .models)
    }

    @Test("the Workloads sub-tab and its namespace filter restore from the user defaults")
    func workloadsView() {
        #expect(WorkloadsView.restore(from: "events") == .events)
        #expect(WorkloadsView.restore(from: "logs") == .pods)
        #expect(WorkloadsView.restore(from: nil) == .pods)
        #expect(WorkloadsView.restoreNamespace(from: "") == nil)
        #expect(WorkloadsView.restoreNamespace(from: "shop") == "shop")
        #expect(WorkloadsView.restoreNamespace(from: 3) == nil)
    }
}
