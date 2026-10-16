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

@Suite("the console window's restored frame")
struct WindowFrameTests {
    typealias Rect = WindowFrame.Rect

    private static let main = WindowFrame.Screen(id: "main", visible: Rect(x: 0, y: 0, width: 1512, height: 944))
    private static let side = WindowFrame.Screen(id: "side", visible: Rect(x: 1512, y: 0, width: 2560, height: 1415))
    private static let minimum = WindowFrame.Size(width: 1180, height: 700)

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let saved: WindowFrame.Saved?
        let screens: [WindowFrame.Screen]
        let want: Rect?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "still-connected screen kept as is",
             saved: .init(frame: Rect(x: 1700, y: 200, width: 1400, height: 900), screen: "side"),
             screens: [main, side],
             want: Rect(x: 1700, y: 200, width: 1400, height: 900)),
        Case(name: "disconnected display moved to main, centred",
             saved: .init(frame: Rect(x: 1700, y: 200, width: 1300, height: 800), screen: "side"),
             screens: [main],
             want: Rect(x: 106, y: 72, width: 1300, height: 800)),
        Case(name: "partly off the right and bottom edges moved on",
             saved: .init(frame: Rect(x: 400, y: -100, width: 1200, height: 750), screen: "main"),
             screens: [main, side],
             want: Rect(x: 312, y: 0, width: 1200, height: 750)),
        Case(name: "partly off the left and top edges moved on",
             saved: .init(frame: Rect(x: -300, y: 400, width: 1200, height: 750), screen: "main"),
             screens: [main],
             want: Rect(x: 0, y: 194, width: 1200, height: 750)),
        Case(name: "larger than the screen shrunk to fit",
             saved: .init(frame: Rect(x: -50, y: -50, width: 3000, height: 2000), screen: "main"),
             screens: [main],
             want: Rect(x: 0, y: 0, width: 1512, height: 944)),
        // Grown from its top edge (600), the bottom would be at -100, so it moves up onto the screen.
        Case(name: "below the minimum grown to it",
             saved: .init(frame: Rect(x: 100, y: 200, width: 600, height: 400), screen: "main"),
             screens: [main],
             want: Rect(x: 100, y: 0, width: 1180, height: 700)),
        Case(name: "nothing saved keeps the centred placement",
             saved: nil, screens: [main, side], want: nil),
        Case(name: "no screen at all keeps the centred placement",
             saved: .init(frame: Rect(x: 0, y: 0, width: 1200, height: 750), screen: "main"),
             screens: [], want: nil),
    ]

    @Test("restored frame clamps onto a visible screen", arguments: cases)
    func restoredFrameClampsOntoAVisibleScreen(_ c: Case) {
        let got = WindowFrame.restore(saved: c.saved, screens: c.screens, minimum: Self.minimum)
        #expect(got == c.want)
        guard let got else { return }
        #expect(got.width >= Self.minimum.width && got.height >= Self.minimum.height)
        let visible = (c.screens.first { $0.id == c.saved?.screen } ?? c.screens[0]).visible
        #expect(got.x >= visible.x && got.maxX <= visible.maxX)
        #expect(got.y >= visible.y && got.maxY <= visible.maxY)
    }

    @Test("a minimum larger than the screen wins, pinned to its left and top edges")
    func minimumLargerThanScreen() {
        let small = WindowFrame.Screen(id: "small", visible: Rect(x: 0, y: 0, width: 1024, height: 640))
        let saved = WindowFrame.Saved(frame: Rect(x: 10, y: 10, width: 900, height: 600), screen: "small")
        let got = WindowFrame.restore(saved: saved, screens: [small], minimum: Self.minimum)
        #expect(got == Rect(x: 0, y: -60, width: 1180, height: 700))
    }

    @Test("the saved frame round-trips through the user defaults; anything else reads as nothing saved")
    func savedRoundTrips() {
        let saved = WindowFrame.Saved(frame: Rect(x: 12.5, y: -40, width: 1300, height: 820), screen: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        #expect(WindowFrame.Saved(defaultsValue: saved.defaultsValue) == saved)
        #expect(WindowFrame.Saved(defaultsValue: nil) == nil)
        #expect(WindowFrame.Saved(defaultsValue: "1 2 3 4") == nil)
        #expect(WindowFrame.Saved(defaultsValue: ["x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0]) == nil)
        #expect(WindowFrame.Saved(defaultsValue: ["x": 1.0, "y": 2.0, "width": -3.0, "height": 4.0, "screen": "a"]) == nil)
        #expect(WindowFrame.Saved(defaultsValue: ["x": Double.nan, "y": 2.0, "width": 3.0, "height": 4.0, "screen": "a"]) == nil)
    }
}
