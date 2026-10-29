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
import SwiftUI

/// LogTextView is how every log in the app is drawn: the log pane's pod and
/// build logs and the root step's log tail. It is an AppKit text view in a
/// scroll view (`LogTextScroller`), because a SwiftUI `Text` wraps or
/// clips a long line and has no horizontal scroller: lines never wrap, the
/// bottom scroller reaches the end of the longest line, the text stays
/// selectable and copyable, and a growing log is appended rather than laid
/// out again. `count` is the bytes read: when it changes and is not -1 the
/// view follows the log's end, vertically only.
struct LogTextView: NSViewRepresentable {
    let text: String
    let count: Int
    var fontSize: CGFloat = 11
    var inset: CGFloat = 12

    func makeCoordinator() -> LogTextScroller {
        LogTextScroller(fontSize: fontSize, inset: inset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let scroller = context.coordinator
        let follow = count >= 0 && count != scroller.lastCount
        scroller.lastCount = count
        scroller.show(text, follow: follow)
    }
}

/// LogTextScroller owns one log view's scroll view and text view, and the
/// incremental width of its longest line (`LogColumns`).
@MainActor
final class LogTextScroller {
    /// The text container's width: no line ever reaches it, so none wraps.
    static let unbounded: CGFloat = 1e7

    let scrollView: LogScrollView
    let textView: NSTextView
    let font: NSFont
    /// One column's width in the font.
    let advance: CGFloat
    private let attributes: [NSAttributedString.Key: Any]
    private let inset: CGFloat

    /// The columns of the text shown, counted as it was appended.
    private(set) var columns = LogColumns()
    /// Whether the last `show` appended to the text rather than replacing it.
    private(set) var appendedLast = false
    /// The text shown, to tell an append from a new log.
    private var shown = ""
    /// The bytes read at the last update; `LogTextView` follows on a change.
    var lastCount = -1

    init(fontSize: CGFloat, inset: CGFloat) {
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        self.inset = inset
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.tabStops = []
        paragraph.defaultTabInterval = advance * CGFloat(LogColumns.tabStop)
        attributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]

        let container = NSTextContainer(size: NSSize(width: Self.unbounded, height: Self.unbounded))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)

        textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.typingAttributes = attributes
        textView.defaultParagraphStyle = paragraph
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)

        scrollView = LogScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.onTile = { [weak self] in self?.fit() }
    }

    /// The width that shows the longest line whole.
    var contentWidth: Double {
        columns.width(advance: Double(advance), inset: Double(inset),
                      padding: Double(textView.textContainer?.lineFragmentPadding ?? 0))
    }

    /// show puts `text` in the view: only its new end when it extends the
    /// text shown, otherwise all of it in place of the old log (the scroll
    /// position stays where AppKit can keep it). With `follow` the view then scrolls to the end, keeping
    /// its horizontal position.
    func show(_ text: String, follow: Bool) {
        guard let storage = textView.textStorage else { return }
        let old = shown.utf8.count
        if text.utf8.count >= old, text.utf8.starts(with: shown.utf8) {
            appendedLast = true
            if text.utf8.count > old {
                let end = String(Substring(text.utf8.dropFirst(old)))
                columns.append(end)
                storage.append(NSAttributedString(string: end, attributes: attributes))
            }
        } else {
            appendedLast = false
            columns = LogColumns(text)
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        shown = text
        fit()
        if follow { followEnd() }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// fit sizes the text view to the longest line, or the visible width
    /// when that is wider, and at least the visible height.
    func fit() {
        let visible = scrollView.contentSize
        let width = max(CGFloat(contentWidth), visible.width)
        textView.minSize = NSSize(width: width, height: visible.height)
        if textView.frame.width != width || textView.frame.height < visible.height {
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, visible.height)))
        }
        textView.sizeToFit()
    }

    /// followEnd scrolls to the last line without moving sideways.
    private func followEnd() {
        let clip = scrollView.contentView
        let x = clip.bounds.origin.x
        let length = textView.textStorage?.length ?? 0
        if length > 0 {
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
        }
        textView.sizeToFit()
        let y = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: x, y: y))
    }
}

/// LogScrollView refits its log's width whenever AppKit lays it out, so a
/// window resize keeps the text at least as wide as what is visible.
final class LogScrollView: NSScrollView {
    var onTile: (() -> Void)?

    override func tile() {
        super.tile()
        onTile?()
    }
}
