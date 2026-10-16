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

/// A Service row as the Services tab decodes one, for the action tests.
func serviceRow(
    _ name: String, namespace: String = "shop", type: String = "ClusterIP", clusterIP: String = "10.43.0.20",
    ports: [ServicePort] = [], hosts: [String] = [], tlsHosts: [String] = [], uid: String = "uid-1"
) -> ServiceRow {
    ServiceRow(
        key: "\(namespace)/\(name)", namespace: namespace, name: name, type: type, clusterIP: clusterIP,
        ports: [], hosts: hosts, uid: uid, servicePorts: ports, tlsHosts: tlsHosts, endpoints: nil)
}

@Suite("the console's service actions")
struct ServiceActionsTests {
    @Test("the API server's service and every kube-system service offer only the copies")
    func serviceActionsRefuseTheAPIServerService() throws {
        let web = [ServicePort(name: "http", port: 80, nodePort: 30080, proto: "TCP")]
        let refused = [
            serviceRow("kubernetes", namespace: "default", clusterIP: "10.43.0.1", ports: web),
            serviceRow("kube-dns", namespace: "kube-system", clusterIP: "10.43.0.10", ports: web),
            serviceRow("traefik", namespace: "kube-system", type: "LoadBalancer", ports: web, hosts: ["shop.example.test"]),
        ]
        for row in refused {
            #expect(ServiceActions.refuses(namespace: row.namespace, name: row.name))
            let menu = ServiceActions.menu(for: row)
            #expect(menu.items.isEmpty, "\(row.key) offers a change")
            #expect(menu.deleteKeyItem == nil)
            #expect(menu.local.map(\.id) == ["copy-ip", "copy-dns"])
            for action in ServiceAction.allCases {
                #expect(ServiceActions.request(action, for: row) == nil)
            }
        }
        // A service named kubernetes elsewhere, and one in default, are not the API server's.
        for row in [serviceRow("kubernetes", namespace: "shop", ports: web), serviceRow("web", namespace: "default", ports: web)] {
            #expect(!ServiceActions.refuses(namespace: row.namespace, name: row.name))
            let menu = ServiceActions.menu(for: row)
            #expect(menu.local.map(\.id) == ["copy-ip", "copy-dns", "open", "copy-url"])
            #expect(menu.items.map(\.title) == ["Delete…"])
            #expect(menu.deleteKeyItem?.id == "delete:\(row.key)")
        }
    }

    @Test("the copies are the cluster IP and the service's DNS name")
    func copies() throws {
        let menu = ServiceActions.menu(for: serviceRow("web"))
        #expect(menu.local.map(\.title) == ["Copy Cluster IP", "Copy DNS Name"])
        #expect(menu.local.map(\.action) == [.copy("10.43.0.20"), .copy("web.shop.svc.cluster.local")])
        // A headless service has no address to copy; an address that is not one is not copied.
        #expect(ServiceActions.clusterIP(serviceRow("db", clusterIP: "None")) == nil)
        #expect(ServiceActions.clusterIP(serviceRow("db", clusterIP: "")) == nil)
        #expect(ServiceActions.clusterIP(serviceRow("db", clusterIP: "10.0.0.1 evil")) == nil)
        #expect(ServiceActions.clusterIP(serviceRow("db", clusterIP: "fd00:10:43::1")) == "fd00:10:43::1")
        // A name ResourceName refuses has no DNS copy and no request.
        let hostile = serviceRow("a b", namespace: "-A")
        #expect(ServiceActions.dnsName(hostile) == nil)
        #expect(ServiceActions.request(.delete, for: hostile) == nil)
        #expect(ServiceActions.menu(for: hostile).local.map(\.id) == ["copy-ip"])
        // A service listed without a UID offers no delete.
        #expect(ServiceActions.menu(for: serviceRow("web", uid: "")).items.isEmpty)
    }

    struct URLCase: Sendable, CustomTestStringConvertible {
        let name: String
        let ports: [ServicePort]
        let hosts: [String]
        let tls: [String]
        let want: String?
        var testDescription: String { name }
    }

    static let urlCases: [URLCase] = [
        URLCase(name: "an Ingress host without TLS opens http", ports: [], hosts: ["shop.example.test"], tls: [], want: "http://shop.example.test"),
        URLCase(name: "an Ingress host under TLS opens https", ports: [], hosts: ["shop.example.test"], tls: ["shop.example.test"], want: "https://shop.example.test"),
        URLCase(name: "a wildcard host is skipped for the next whole name", ports: [], hosts: ["*", "*.example.test", "b.example.test"], tls: [], want: "http://b.example.test"),
        URLCase(name: "only a wildcard host and no web node port opens nothing", ports: [], hosts: ["*"], tls: [], want: nil),
        URLCase(name: "an Ingress host wins over a node port", ports: [ServicePort(name: "http", port: 80, nodePort: 30080, proto: "TCP")],
                hosts: ["shop.example.test"], tls: [], want: "http://shop.example.test"),
        URLCase(name: "a node port named http", ports: [ServicePort(name: "http", port: 9000, nodePort: 30080, proto: "TCP")], hosts: [], tls: [], want: "http://127.0.0.1:30080"),
        URLCase(name: "a node port on 80", ports: [ServicePort(name: nil, port: 80, nodePort: 31000, proto: "TCP")], hosts: [], tls: [], want: "http://127.0.0.1:31000"),
        URLCase(name: "a node port on 8080", ports: [ServicePort(name: "web", port: 8080, nodePort: 31001, proto: "TCP")], hosts: [], tls: [], want: "http://127.0.0.1:31001"),
        URLCase(name: "a node port named https opens https", ports: [ServicePort(name: "https", port: 8443, nodePort: 31443, proto: "TCP")], hosts: [], tls: [], want: "https://127.0.0.1:31443"),
        URLCase(name: "a node port on 443 opens https", ports: [ServicePort(name: nil, port: 443, nodePort: 31444, proto: "TCP")], hosts: [], tls: [], want: "https://127.0.0.1:31444"),
        URLCase(name: "the first web port in the service's order", ports: [ServicePort(name: "metrics", port: 9100, nodePort: 32000, proto: "TCP"),
                                                                           ServicePort(name: "https", port: 443, nodePort: 32443, proto: "TCP"),
                                                                           ServicePort(name: "http", port: 80, nodePort: 32080, proto: "TCP")],
                hosts: [], tls: [], want: "https://127.0.0.1:32443"),
        URLCase(name: "a web port without a node port opens nothing", ports: [ServicePort(name: "http", port: 80, nodePort: nil, proto: "TCP")], hosts: [], tls: [], want: nil),
        URLCase(name: "a UDP port opens nothing", ports: [ServicePort(name: "http", port: 80, nodePort: 30053, proto: "UDP")], hosts: [], tls: [], want: nil),
        URLCase(name: "another node port opens nothing", ports: [ServicePort(name: "db", port: 5432, nodePort: 30432, proto: "TCP")], hosts: [], tls: [], want: nil),
        URLCase(name: "a node port out of range opens nothing", ports: [ServicePort(name: "http", port: 80, nodePort: 70000, proto: "TCP")], hosts: [], tls: [], want: nil),
    ]

    @Test("the browser address", arguments: urlCases)
    func browserURL(_ c: URLCase) {
        let row = serviceRow("web", type: "NodePort", ports: c.ports, hosts: c.hosts, tlsHosts: c.tls)
        #expect(ServiceActions.browserURL(for: row)?.absoluteString == c.want)
        let menu = ServiceActions.menu(for: row)
        if let want = c.want {
            #expect(menu.local.suffix(2).map(\.title) == ["Open in Browser", "Copy URL"])
            #expect(menu.local.suffix(2).map(\.action) == [.open(try! #require(URL(string: want))), .copy(want)])
        } else {
            #expect(!menu.local.contains { $0.id == "open" || $0.id == "copy-url" })
        }
    }

    @Test("the decoded fixture's web service opens its Ingress host over TLS")
    func fixtureURL() throws {
        let rows = try ServicesList.decode(try fixture("kubectl_services_ingress.json"))
        let web = try #require(rows.first { $0.key == "shop/web" })
        #expect(web.uid == "5a1d2c3e-0000-4000-8000-000000000020")
        #expect(web.tlsHosts == ["shop.example.test"])
        #expect(web.servicePorts == [ServicePort(name: "http", port: 80, nodePort: 30080, proto: "TCP"),
                                     ServicePort(name: "https", port: 443, nodePort: nil, proto: "TCP")])
        #expect(ServiceActions.browserURL(for: web)?.absoluteString == "https://shop.example.test")
    }

    @Test("the service delete and its UID read are fixed argument lists")
    func argumentsGolden() throws {
        let ns = try #require(ResourceName("shop"))
        let svc = try #require(ResourceName("web"))
        #expect(K3smCLI.deleteServiceArguments(namespace: ns, service: svc)
            == ["kubectl", "delete", "service", "web", "-n", "shop", "--wait=false"])
        #expect(K3smCLI.serviceUIDArguments(namespace: ns, service: svc)
            == ["kubectl", "get", "service", "web", "-n", "shop", "-o", "jsonpath={.metadata.uid}"])
        #expect(K3smCLI.endpointSlicesArguments == ["kubectl", "get", "endpointslices", "-A", "-o", "json"])
        let request = try #require(ServiceActions.request(.delete, for: serviceRow("web", hosts: ["shop.example.test"])))
        #expect(request.arguments == K3smCLI.deleteServiceArguments(namespace: ns, service: svc))
        #expect(request.precheckArguments == K3smCLI.serviceUIDArguments(namespace: ns, service: svc))
        #expect(request.section == .services && request.rowKey == "shop/web" && request.kind == .delete)
        #expect(request.confirmation.title == "Delete service shop/web?")
        #expect(request.confirmation.destructive)
        #expect(request.confirmation.message.contains("Its pods keep running."))
        #expect(request.confirmation.message.contains("(shop.example.test) stop answering"))
    }

    @Test("the UID read refuses a service that changed and lets the confirmed one run")
    func uidPrecheck() throws {
        let request = try #require(ServiceActions.request(.delete, for: serviceRow("web", uid: "uid-1")))
        #expect(request.precheck(.exited(status: 0, output: Data("uid-1\n".utf8))) == nil)
        let changed = ActionOutcome.refused("Delete refused: the service changed since you clicked; nothing was deleted.")
        #expect(request.precheck(.exited(status: 0, output: Data("uid-2".utf8))) == changed)
        #expect(request.precheck(.exited(status: 1, output: Data(#"Error from server (NotFound): services "web" not found"#.utf8))) == changed)
        #expect(request.precheck(.exited(status: 1, output: Data("forbidden\u{202E}".utf8)))
            == .failed("Delete failed; nothing was deleted. kubectl said: forbidden"))
        #expect(request.precheck(.noAnswer)?.failed == true)
        #expect(request.precheck(.missing) == .failed("Delete failed: k3sm is not installed on this Mac."))
    }

    @Test("a delete's run is reported in one line")
    func reports() throws {
        let request = try #require(ServiceActions.request(.delete, for: serviceRow("web")))
        #expect(request.report(.exited(status: 0, output: Data())) == .succeeded("Delete asked: the service shop/web is being removed."))
        #expect(request.report(.exited(status: 1, output: Data("Error: nope\n".utf8))) == .failed("Delete failed. kubectl said: Error: nope"))
        #expect(request.report(.exited(status: 2, output: Data())) == .failed("Delete failed: k3sm kubectl exited 2"))
        #expect(request.report(.noAnswer).failed)
    }
}

@Suite("the Services tab's endpoint counts")
struct ServiceEndpointsTests {
    @Test("ready endpoints are counted per service from the EndpointSlices")
    func endpointCounts() throws {
        let counts = try ServicesList.endpointCounts(try fixture("kubectl_endpointslices.json"))
        // web-1 sits in both address families and counts once; an unset ready
        // reads as ready; a not-ready endpoint and an unlabelled slice do not count.
        // A service whose endpoints are all not ready has no entry (the rows read it as 0).
        #expect(counts == ["shop/web": 2, "default/kubernetes": 1, "default/web": 1])
    }

    @Test("the counts reach the rows, and a failed slice read leaves them not reported")
    func mergedIntoRows() throws {
        let services = try fixture("kubectl_services_ingress.json")
        let slices = try fixture("kubectl_endpointslices.json")
        guard case .value(let rows) = ServicesList.tabResult(listExit: 0, listStdout: services, endpoints: (0, slices)) else {
            Issue.record("want rows"); return
        }
        #expect(rows.map(\.endpoints) == [1, 0, 2])
        #expect(InspectorDetails.endpointsText(rows[2]) == "2 ready")
        #expect(InspectorDetails.endpointsText(rows[1]) == "none ready")
        for failed: (exit: Int32, stdout: Data)? in [nil, (1, slices), (0, Data("not json".utf8)), (0, services)] {
            guard case .value(let rows) = ServicesList.tabResult(listExit: 0, listStdout: services, endpoints: failed) else {
                Issue.record("a failed slice read failed the tab"); return
            }
            #expect(rows.allSatisfy { $0.endpoints == nil })
            #expect(InspectorDetails.endpointsText(rows[0]) == "not reported")
        }
        // The list still decides the tab.
        #expect(ServicesList.tabResult(listExit: 1, listStdout: Data(), endpoints: (0, slices)) == .failed("k3sm kubectl exited 1"))
        #expect(InspectorDetails.endpointsText(serviceRow("ext", type: "ExternalName")) == "not used (ExternalName)")
    }
}
