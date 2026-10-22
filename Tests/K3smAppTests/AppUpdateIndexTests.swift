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

import K3smStatus
import Testing

@testable import K3smApp

/// The verified index a check returns is kept for the download step only
/// when the check's state is an offer; every other state clears it, so a
/// signature-valid index at or below the running build never reaches it.
@Suite("the app update index the model keeps")
struct AppUpdateIndexTests {
    @Test func onlyAnOfferKeepsTheIndex() {
        #expect(AppModel.keepsAppUpdateIndex(after: .available(tag: "v0.3.0")))
        let others: [AppUpdateState] = [
            .buildIsNewer(own: "v0.2.0", latest: "v0.1.0"), .upToDate(tag: "v0.2.0"), .downloading, .verifying,
            .development, .requiresNewerMacOS("27.0"), .couldNotCheck(reason: "x"), .checksOff, .notCheckedYet,
        ]
        for state in others {
            #expect(!AppModel.keepsAppUpdateIndex(after: state), "\(state.caseName) keeps the index")
        }
    }
}
