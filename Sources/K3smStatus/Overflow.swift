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

/// Overflow decides how a pane fits content laid out for a natural size into
/// the room the window gives it. On each axis the content is drawn at the
/// larger of the two (`extent`), so it never squeezes below what it was laid
/// out for and still fills a larger pane; when the room is the smaller, the
/// pane scrolls on that axis (`scrolls`). So the window's minimum need not
/// cover every pane's content: a pane that does not fit scrolls.
public enum Overflow {
    /// The size to draw content at on one axis: `natural`, or the room when
    /// it is larger. A room that is not a finite positive number (before
    /// the first layout) draws at `natural`.
    public static func extent(room: Double, natural: Double) -> Double {
        let floor = natural.isFinite ? max(0, natural) : 0
        guard room.isFinite, room > 0 else { return floor }
        return max(room, floor)
    }

    /// Whether the pane scrolls on one axis: its room is smaller than the
    /// content's natural size.
    public static func scrolls(room: Double, natural: Double) -> Bool {
        extent(room: room, natural: natural) > max(0, room.isFinite ? room : 0)
    }
}
