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

extension WindowFrame {
    /// Whether the console draws its inspector: the details button has it
    /// shown and the strip is shown (`ConsolePane.stripShown`). While the
    /// set-up flow fills the content pane the inspector is not drawn, so it
    /// neither counts toward the window's minimum nor grows the window.
    public static func inspectorDrawn(inspectorShown: Bool, stripShown: Bool) -> Bool {
        inspectorShown && stripShown
    }

    /// Whether the inspector counts toward the minimum the saved frame is
    /// restored against before the window first shows: whenever the details
    /// button has it shown, whatever the strip, since that is the minimum the
    /// window has once the tabs show. Placing against it means the strip
    /// showing after launch does not grow, move or re-save the window.
    public static func inspectorCountsAtPlacement(inspectorShown: Bool) -> Bool {
        inspectorShown
    }

    /// Whether the window grows when `inspectorDrawn` changes from `previous`
    /// to `current`: only when the inspector turns drawn.
    public static func inspectorGrows(from previous: Bool, to current: Bool) -> Bool {
        !previous && current
    }

    /// Whether the window grows to a raised minimum at all: not while it is
    /// full screen or zoomed. Such a window's frame belongs to the system,
    /// and setting a frame on it would break it out of that state.
    public static func growRuns(fullScreen: Bool, zoomed: Bool) -> Bool {
        !fullScreen && !zoomed
    }

    /// The frame an already-placed window takes when its minimum rises (the
    /// inspector opening): a frame narrower or shorter than `minimum` grows
    /// to exactly that minimum, one already at or past it is returned
    /// unchanged. Growth keeps the frame's left and top edges, then moves the
    /// frame back onto `visible` (the screen's visible frame, nil when the
    /// window is on no screen) as `restore` does: a frame the minimum makes
    /// larger than `visible` is pinned to its left and top edges.
    public static func grown(_ frame: Rect, minimum: Size, visible: Rect?) -> Rect {
        let width = max(frame.width, minimum.width)
        let height = max(frame.height, minimum.height)
        guard width != frame.width || height != frame.height else { return frame }
        var grown = Rect(x: frame.x, y: frame.maxY - height, width: width, height: height)
        guard let visible else { return grown }
        grown.x = width > visible.width ? visible.x : min(max(grown.x, visible.x), visible.maxX - width)
        grown.y = height > visible.height ? visible.maxY - height : min(max(grown.y, visible.y), visible.maxY - height)
        return grown
    }
}
