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

/// The home of the popover version cards' tests. Today it pins only the
/// shape of the contract sketch in `VersionCards.swift`; the implementation
/// adds the tests of which cards show and what each says here.
@Suite("the popover version cards' contract")
struct VersionCardsTests {
    @Test func versionCardHasItsShape() {
        let card = VersionCard(eyebrow: "INSTALLED", value: "0.1.8", note: nil)
        let eyebrow: String = card.eyebrow
        let value: String = card.value
        let note: String? = card.note
        _ = (eyebrow, value, note)
    }

    private static let installed = SemanticVersion("0.1.8")!
    private static let release = AppVersion(shortVersion: "0.1.9", buildVersion: nil)
    private static let carried = AppVersion.payloadRelease(shortVersion: "0.1.9")!

    @Test("the first card is the installed k3sm, unknown when it cannot be read")
    func installedCard() {
        let cards = Self.release.versionCards(installed: Self.installed, payload: Self.carried)
        #expect(cards.count == 2)
        #expect(cards[0] == VersionCard(eyebrow: "INSTALLED", value: "0.1.8", note: nil))
        #expect(Self.release.versionCards(installed: nil, payload: Self.carried)[0]
            == VersionCard(eyebrow: "INSTALLED", value: "unknown", note: nil))
    }

    @Test("a release build's second card relates the carried release to the installed one", arguments: [
        ("0.1.8", "a newer release"),
        ("0.1.9", "up to date"),
        ("0.2.0", "an older release"),
    ])
    func carriedRelease(installed: String, note: String) throws {
        let current = try #require(SemanticVersion(installed))
        let cards = Self.release.versionCards(installed: current, payload: Self.carried)
        #expect(cards[1] == VersionCard(eyebrow: "THIS APP", value: "0.1.9", note: note))
        // The line the cards replace still says the same thing, for accessibility.
        #expect(Self.release.versionLine(installed: current, payload: Self.carried).contains(note.replacingOccurrences(of: "up to date", with: "up to date with this app")))
    }

    @Test("with the installed release unknown, the carried release has no note")
    func carriedReleaseWithoutInstalled() {
        let cards = Self.release.versionCards(installed: nil, payload: Self.carried)
        #expect(cards[1] == VersionCard(eyebrow: "THIS APP", value: "0.1.9", note: nil))
    }

    @Test("a development build's second card is its pseudo-version, never 0.0.0, with the development note")
    func developmentBuild() {
        let pseudo = "v0.0.0-0.20261017002053-910af952ea03"
        let development = AppVersion(shortVersion: "0.0.0", buildVersion: pseudo)
        let payload = AppVersion.payloadRelease(shortVersion: "0.0.0")
        #expect(payload == nil)
        let cards = development.versionCards(installed: Self.installed, payload: payload)
        #expect(cards[0].value == "0.1.8")
        #expect(cards[1] == VersionCard(eyebrow: "THIS APP", value: pseudo, note: "development build"))
        #expect(!cards[1].value.replacingOccurrences(of: pseudo, with: "").contains("0.0.0"))
        #expect(development.versionCards(installed: nil, payload: payload)[0].value == "unknown")
    }

    @Test("a binary outside a bundle shows unknown for the app, with no note")
    func noBundle() {
        let bare = AppVersion(shortVersion: nil, buildVersion: nil)
        let cards = bare.versionCards(installed: Self.installed, payload: nil)
        #expect(cards[1] == VersionCard(eyebrow: "THIS APP", value: "unknown", note: nil))
    }
}
