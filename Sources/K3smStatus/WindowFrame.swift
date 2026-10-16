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

/// WindowFrame decides where the console window reopens. The window saves
/// its frame and the identity of the screen it was on whenever it moves,
/// resizes or closes (`Saved`, kept in the user defaults under `key`), and
/// `restore` puts that frame back on the next open, clamped onto a screen
/// the user can see. Coordinates are AppKit's global screen space (origin at
/// the bottom left, y up); nothing here touches AppKit, so the clamp is
/// tested without a display.
public enum WindowFrame {
    /// The user-defaults key of the saved frame.
    public static let key = "consoleWindowFrame"

    /// A rectangle in global screen coordinates.
    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// A width and a height.
    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// A connected screen: a stable identity and its visible frame (the
    /// frame less the menu bar and the Dock).
    public struct Screen: Equatable, Sendable {
        public var id: String
        public var visible: Rect

        public init(id: String, visible: Rect) {
            self.id = id
            self.visible = visible
        }
    }

    /// The frame the window last had and the identity of its screen.
    public struct Saved: Equatable, Sendable {
        public var frame: Rect
        public var screen: String

        public init(frame: Rect, screen: String) {
            self.frame = frame
            self.screen = screen
        }

        /// The value stored in the user defaults: a property-list dictionary.
        public var defaultsValue: [String: Any] {
            ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height, "screen": screen]
        }

        /// Reads a stored value back. Anything that is not a dictionary of
        /// four finite numbers, a positive size and a screen identity reads
        /// as nothing saved.
        public init?(defaultsValue: Any?) {
            guard let dict = defaultsValue as? [String: Any],
                  let x = Self.number(dict["x"]), let y = Self.number(dict["y"]),
                  let width = Self.number(dict["width"]), let height = Self.number(dict["height"]),
                  width > 0, height > 0,
                  let screen = dict["screen"] as? String, !screen.isEmpty
            else { return nil }
            self.init(frame: Rect(x: x, y: y, width: width, height: height), screen: screen)
        }

        private static func number(_ value: Any?) -> Double? {
            guard let value = value as? Double, value.isFinite else { return nil }
            return value
        }
    }

    /// The frame to open the window at, or nil for today's centred placement
    /// (nothing saved, or no screen connected).
    ///
    /// `screens` lists the connected screens with the main screen first. The
    /// saved frame goes back on its own screen when that screen is still
    /// connected; otherwise it moves to the main screen, centred on its
    /// visible frame. Its size is never below `minimum` and, the minimum
    /// allowing, never larger than the visible frame; a size change keeps the
    /// frame's top edge. A frame partly off the visible frame is moved on;
    /// one the minimum makes larger than it is pinned to its left and top
    /// edges, so the title bar stays reachable.
    public static func restore(saved: Saved?, screens: [Screen], minimum: Size) -> Rect? {
        guard let saved, let main = screens.first else { return nil }
        let known = screens.first { $0.id == saved.screen }
        let visible = (known ?? main).visible

        var frame = saved.frame
        let width = max(minimum.width, min(frame.width, visible.width))
        let height = max(minimum.height, min(frame.height, visible.height))
        frame.y = frame.maxY - height
        frame.width = width
        frame.height = height

        if known == nil {
            frame.x = visible.x + (visible.width - width) / 2
            frame.y = visible.y + (visible.height - height) / 2
        }
        frame.x = width > visible.width ? visible.x : min(max(frame.x, visible.x), visible.maxX - width)
        frame.y = height > visible.height ? visible.maxY - height : min(max(frame.y, visible.y), visible.maxY - height)
        return frame
    }
}
