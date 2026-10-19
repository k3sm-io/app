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

/// VersionCard is one of the info popover's version cards: a small-caps
/// eyebrow naming what the card is about, the version itself, and an
/// optional note under it ("INSTALLED" over "0.1.8"; "THIS APP" over
/// "1.2.3" with "a newer release").
///
/// The cards carry the same facts as `AppVersion.versionLine(installed:payload:)`
/// and are unit-tested for the same cases: a payload release that is newer,
/// the same or older than the installed one, no installed release, and no
/// payload release. Which cards show, their eyebrows, values and notes are
/// decided here in `K3smStatus`; a view only renders the cards it is given.
/// No view uses them yet: the popover still shows `versionLine`.
public struct VersionCard: Equatable, Sendable {
    /// The small-caps label over the version ("INSTALLED", "THIS APP").
    public let eyebrow: String
    /// The version as shown, clipped like any other line; "unknown" when
    /// it cannot be read.
    public let value: String
    /// A line under the version that relates it to the other card; nil
    /// when there is nothing to add.
    public let note: String?

    public init(eyebrow: String, value: String, note: String?) {
        self.eyebrow = eyebrow
        self.value = value
        self.note = note
    }

    /// The first card's eyebrow: the k3sm installed on this Mac.
    public static let installedEyebrow = "INSTALLED"
    /// The second card's eyebrow: the release this app carries, or the app
    /// itself when it carries none.
    public static let appEyebrow = "THIS APP"
    /// The second card's note under a development build's pseudo-version.
    public static let developmentNote = "development build"
}

extension AppVersion {
    /// The status popover's two version cards, the same cases as
    /// `versionLine(installed:payload:)`, which stays as the cards'
    /// accessibility text. The first card is the installed k3sm ("unknown"
    /// when it cannot be read). The second is the release this app carries,
    /// with a note that relates it to the installed one ("a newer release",
    /// "up to date", "an older release"; none when the installed release is
    /// unknown), or, for a build that carries no release, the app's own
    /// version (`text`, the pseudo-version, never `0.0.0`) with the
    /// development note; "unknown" for a binary outside a bundle.
    public func versionCards(installed: SemanticVersion?, payload: SemanticVersion?) -> [VersionCard] {
        let first = VersionCard(eyebrow: VersionCard.installedEyebrow, value: installed?.description ?? "unknown", note: nil)
        guard let payload else {
            let note = isDevelopment ? VersionCard.developmentNote : nil
            return [first, VersionCard(eyebrow: VersionCard.appEyebrow, value: text ?? "unknown", note: note)]
        }
        guard let current = installed else {
            return [first, VersionCard(eyebrow: VersionCard.appEyebrow, value: payload.description, note: nil)]
        }
        let note: String
        switch PayloadRelation(payload: payload, installed: current) {
        case .newer: note = "a newer release"
        case .same: note = "up to date"
        case .older: note = "an older release"
        }
        return [first, VersionCard(eyebrow: VersionCard.appEyebrow, value: payload.description, note: note)]
    }
}
