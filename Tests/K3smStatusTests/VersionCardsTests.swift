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
}
