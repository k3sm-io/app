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

import Testing

@testable import K3smStatus

@Suite("ImagesLoadingIndicatorPlacement")
struct ImagesLoadingIndicatorPlacementTests {
    @Test("a content mark beside a visible progress bar is the inline indicator, never the centred one")
    func barVisibleIsInline() {
        #expect(ImagesLoadingIndicator.placement(mark: .content, progressBarVisible: true) == .inline)
    }

    @Test("a content mark with no progress bar stays centred")
    func noBarStaysCentred() {
        #expect(ImagesLoadingIndicator.placement(mark: .content, progressBarVisible: false) == .centred)
    }

    @Test("the label mark and no mark never draw a content indicator")
    func otherMarksDrawNone() {
        for bar in [true, false] {
            #expect(ImagesLoadingIndicator.placement(mark: .label, progressBarVisible: bar) == .none)
            #expect(ImagesLoadingIndicator.placement(mark: nil, progressBarVisible: bar) == .none)
        }
    }

    @Test("the centred overlay is drawn only for the centred placement")
    func overlayOnlyWhenCentred() {
        #expect(ImagesLoadingIndicator.drawsCentredOverlay(.inline) == false)
        #expect(ImagesLoadingIndicator.drawsCentredOverlay(.none) == false)
        #expect(ImagesLoadingIndicator.drawsCentredOverlay(.centred) == true)
    }
}
