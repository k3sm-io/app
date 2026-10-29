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

import AppKit
import K3smStatus
import Testing

@testable import K3smApp

/// These pin the log views' scroller (`LogTextScroller`, behind
/// `LogTextView`): lines never wrap, the horizontal scroller is on, the
/// text's width follows the longest line as the log grows (counted only over
/// what each update appends), and following the tail moves only the vertical
/// position.
@MainActor
@Suite("LogViewScrollsHorizontally")
struct LogViewScrollsHorizontally {
    private func scroller() -> LogTextScroller {
        let scroller = LogTextScroller(fontSize: 11, inset: 12)
        scroller.scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        scroller.scrollView.tile()
        return scroller
    }

    @Test("no line wraps and the horizontal scroller is on")
    func noWrapping() throws {
        let scroller = scroller()
        let container = try #require(scroller.textView.textContainer)
        #expect(scroller.scrollView.hasHorizontalScroller)
        #expect(scroller.scrollView.hasVerticalScroller)
        #expect(!container.widthTracksTextView)
        #expect(container.size.width >= LogTextScroller.unbounded)
        #expect(!scroller.textView.isEditable)
        #expect(scroller.textView.isSelectable)
    }

    @Test("the text's width follows the longest line, counted over each append")
    func widthTracksTheLongestLine() {
        let scroller = scroller()
        scroller.show("short\n", follow: false)
        #expect(scroller.columns.longest == 5)
        #expect(scroller.textView.frame.width == scroller.scrollView.contentSize.width)

        let long = String(repeating: "x", count: 400)
        scroller.show("short\n" + long + "\n", follow: true)
        #expect(scroller.appendedLast)
        #expect(scroller.columns.longest == 400)
        let wide = scroller.textView.frame.width
        #expect(wide == CGFloat(scroller.contentWidth))
        #expect(wide > scroller.scrollView.contentSize.width)
        #expect(wide >= 400 * scroller.advance)

        scroller.show("short\n" + long + "\nend\n", follow: true)
        #expect(scroller.appendedLast)
        #expect(scroller.textView.frame.width == wide)
        #expect(scroller.textView.string == "short\n" + long + "\nend\n")

        scroller.show("another log\n", follow: false)
        #expect(!scroller.appendedLast)
        #expect(scroller.columns.longest == 11)
        #expect(scroller.textView.frame.width == scroller.scrollView.contentSize.width)
    }

    @Test("following the tail keeps the horizontal position")
    func followKeepsTheHorizontalPosition() {
        let scroller = scroller()
        let long = String(repeating: "y", count: 300)
        var text = (0..<40).map { _ in long }.joined(separator: "\n") + "\n"
        scroller.show(text, follow: true)
        let clip = scroller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 150, y: clip.bounds.origin.y))
        text += "one more line\n"
        scroller.show(text, follow: true)
        #expect(clip.bounds.origin.x == 150)
        #expect(abs(clip.bounds.maxY - scroller.textView.frame.height) < 1)
    }
}
