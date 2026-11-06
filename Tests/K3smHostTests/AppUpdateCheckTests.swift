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

/// A fetcher that always answers with one HTTP status, as the shipped one throws it.
private struct StatusFetcher: AppIndexFetcher {
    let status: Int
    func fetch(_ request: URLRequest) async throws -> Data {
        throw AppIndexFetchError.status(status)
    }
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
        let checker = AppUpdateChecker(fetcher: fetcher) { _, _ in throw Refused() }
        let outcome = await checker.check(.automatic, checksOn: false, own: Self.release, firstRun: false, kind: .stable, record: AppUpdateRecord(),
                                          candidateRecord: AppUpdateCandidateRecord())
        #expect(fetcher.count == 0)
        #expect(outcome.result == nil)
        let dev = await checker.check(.user, checksOn: true, own: AppUpdateOwn(tag: "v0.2.0", pinned: false), firstRun: false,
                                      kind: .stable, record: AppUpdateRecord(), candidateRecord: AppUpdateCandidateRecord())
        #expect(fetcher.count == 0 && dev.result == nil)
    }

    @Test("Check Now sends exactly the fixed request, and a refused signature is never an offer")
    func checkNowSendsTheFixedRequest() async throws {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(fetcher: fetcher) { _, _ in throw Refused() }
        let stored = AppUpdateRecord(highTag: "v0.2.0", highIssuedAt: "2026-11-02T18:04:11Z")
        let outcome = await checker.check(.user, checksOn: false, own: Self.release, firstRun: false, kind: .stable, record: stored,
                                          candidateRecord: AppUpdateCandidateRecord())
        #expect(outcome == .init(result: .failed("the signature is not valid"), record: stored, candidateRecord: AppUpdateCandidateRecord()))
        let sent = try #require(fetcher.requests.withLock { $0.first })
        #expect(fetcher.count == 1)
        #expect(sent.url?.absoluteString == "https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m")
        #expect(sent.httpMethod == "GET")
        #expect(sent.allHTTPHeaderFields == ["User-Agent": "k3sm-app"])
        #expect(sent.httpShouldHandleCookies == false)
        #expect(sent.httpBody == nil)
    }

    // MARK: a candidate on the row

    static let candidateTag = "v0.3.0-rc.2"
    static let candidate = ReleaseIndexKind.candidate(tag: candidateTag)
    static let stableFloor = AppUpdateRecord(highTag: "v0.2.0", highIssuedAt: "2026-11-02T18:04:11Z")
    static let signedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// The candidate golden, vendored beside k3sm's corpus in the decoder's tests.
    static func candidateIndex() throws -> ReleaseIndex {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = tests.appendingPathComponent("K3smStatusTests/Fixtures/release-index-rc/index.json")
        return try ReleaseIndex.parse(try Data(contentsOf: file), expected: candidate)
    }

    @Test("a candidate is asked for by tag, on a pinned host, and verified as that kind")
    func aCandidateIsAskedForByTag() async throws {
        let fetcher = CountingFetcher()
        let asked = Mutex<[ReleaseIndexKind]>([])
        let index = try Self.candidateIndex()
        let checker = AppUpdateChecker(fetcher: fetcher) { _, kind in
            asked.withLock { $0.append(kind) }
            return (index, Self.signedAt)
        }
        let outcome = await checker.check(.user, checksOn: false, own: Self.release, firstRun: false, kind: Self.candidate,
                                          record: Self.stableFloor, candidateRecord: AppUpdateCandidateRecord())
        let sent = try #require(fetcher.requests.withLock { $0.first })
        #expect(sent.url?.absoluteString
            == "https://github.com/k3sm-io/k3sm/releases/download/v0.3.0-rc.2/k3sm_0.3.0-rc.2_release-index.p7m")
        #expect(AppUpdateRequest.allowsHop(try #require(sent.url)))
        #expect(sent.allHTTPHeaderFields == ["User-Agent": "k3sm-app"])
        #expect(sent.httpShouldHandleCookies == false)
        #expect(asked.withLock { $0 } == [Self.candidate])
        let latest = try #require(AppUpdateLatest(index: index))
        #expect(outcome == .init(result: .verified(latest), record: Self.stableFloor,
                                 candidateRecord: AppUpdateCandidateRecord(highTag: Self.candidateTag, highIssuedAt: "2026-11-05T12:30:45Z")))
    }

    @Test("a candidate below its floor changes neither record")
    func aCandidateBelowItsFloorIsRefused() async throws {
        let index = try Self.candidateIndex()
        let checker = AppUpdateChecker(fetcher: CountingFetcher()) { _, _ in (index, Self.signedAt) }
        let floor = AppUpdateCandidateRecord(highTag: "v0.3.0-rc.3", highIssuedAt: "2026-11-05T12:30:45Z")
        let outcome = await checker.check(.user, checksOn: false, own: Self.release, firstRun: false, kind: Self.candidate,
                                          record: Self.stableFloor, candidateRecord: floor)
        #expect(outcome == .init(result: .failed(AppUpdateRecord.olderThanSeen), record: Self.stableFloor, candidateRecord: floor))
    }

    @Test("a tag with no document is an answer, and only a candidate's 404 is")
    func aTagWithNoDocumentIsNotAnError() async {
        let floor = AppUpdateCandidateRecord(highTag: "v0.3.0-rc.1", highIssuedAt: "2026-11-05T12:30:45Z")
        func outcome(status: Int, kind: ReleaseIndexKind) async -> AppUpdateChecker.Outcome {
            let checker = AppUpdateChecker(fetcher: StatusFetcher(status: status)) { _, _ in throw Refused() }
            return await checker.check(.user, checksOn: false, own: Self.release, firstRun: false, kind: kind,
                                       record: Self.stableFloor, candidateRecord: floor)
        }
        #expect(await outcome(status: 404, kind: Self.candidate)
            == .init(result: .noCandidateDocument(Self.candidateTag), record: Self.stableFloor, candidateRecord: floor))
        #expect(await outcome(status: 500, kind: Self.candidate).result == .failed("the server answered 500"))
        #expect(await outcome(status: 403, kind: Self.candidate).result == .failed("the server answered 403"))
        #expect(await outcome(status: 404, kind: .stable).result == .failed("the server answered 404"))
    }

    @Test("a tag outside the grammar sends nothing")
    func aBadTagSendsNothing() async {
        let fetcher = CountingFetcher()
        let checker = AppUpdateChecker(fetcher: fetcher) { _, _ in throw Refused() }
        let outcome = await checker.check(.user, checksOn: false, own: Self.release, firstRun: false,
                                          kind: .candidate(tag: "v0.3.0-rc.2/../../evil"), record: Self.stableFloor,
                                          candidateRecord: AppUpdateCandidateRecord())
        #expect(fetcher.count == 0)
        #expect(outcome.result == .failed("no index URL"))
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
