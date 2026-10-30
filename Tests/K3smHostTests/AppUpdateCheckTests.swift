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
import Synchronization
import Testing

@testable import K3smHost
import K3smStatus

/// A fetcher that records every request it is asked to send.
private final class CountingFetcher: AppIndexFetcher {
    let requests = Mutex<[URLRequest]>([])
    func fetch(_ request: URLRequest) async throws -> Data {
        requests.withLock { $0.append(request) }
        return Data("signed".utf8)
    }
    var count: Int { requests.withLock { $0.count } }
}

private struct Refused: Error, CustomStringConvertible {
    var description: String { "the signature is not valid" }
}

@Suite("the app's own update request")
struct AppUpdateCheckTests {
    static let release = AppUpdateOwn(tag: "v0.2.0", pinned: true)

    @Test("checks off sends nothing")
    func checksOffSendsNothing() async {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(fetcher: fetcher) { _ in throw Refused() }
        let outcome = await checker.check(.automatic, checksOn: false, own: Self.release, firstRun: false, record: AppUpdateRecord())
        #expect(fetcher.count == 0)
        #expect(outcome.result == nil)
        let dev = await checker.check(.user, checksOn: true, own: AppUpdateOwn(tag: "v0.2.0", pinned: false), firstRun: false,
                                      record: AppUpdateRecord())
        #expect(fetcher.count == 0 && dev.result == nil)
    }

    @Test("Check Now sends exactly the fixed request, and a refused signature is never an offer")
    func checkNowSendsTheFixedRequest() async throws {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(fetcher: fetcher) { _ in throw Refused() }
        let stored = AppUpdateRecord(highTag: "v0.2.0", highIssuedAt: "2026-11-02T18:04:11Z")
        let outcome = await checker.check(.user, checksOn: false, own: Self.release, firstRun: false, record: stored)
        #expect(outcome == .init(result: .failed("the signature is not valid"), record: stored))
        let sent = try #require(fetcher.requests.withLock { $0.first })
        #expect(fetcher.count == 1)
        #expect(sent.url?.absoluteString == "https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m")
        #expect(sent.httpMethod == "GET")
        #expect(sent.allHTTPHeaderFields == ["User-Agent": "k3sm-app"])
        #expect(sent.httpShouldHandleCookies == false)
        #expect(sent.httpBody == nil)
    }

    @Test("the session stores nothing and adds no header")
    func sessionStoresNothing() {
        let configuration = AppUpdateFetch.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect((configuration.httpAdditionalHeaders ?? [:]).isEmpty)
    }

    @Test("every redirect hop is held to the pinned hosts and carries only the fixed headers")
    func redirects() throws {
        var hop = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/x?sig=1")!)
        hop.setValue("session=1", forHTTPHeaderField: "Cookie")
        let followed = try #require(EphemeralIndexFetcher.redirect(to: hop))
        #expect(followed.allHTTPHeaderFields == ["User-Agent": "k3sm-app"])
        #expect(EphemeralIndexFetcher.redirect(to: URLRequest(url: URL(string: "https://example.com/x")!)) == nil)
        #expect(EphemeralIndexFetcher.redirect(to: URLRequest(url: URL(string: "http://github.com/x")!)) == nil)
    }
}
