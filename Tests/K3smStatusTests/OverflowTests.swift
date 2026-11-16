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

@Suite("a pane too small for its content scrolls")
struct OverflowTests {
    @Test("content is drawn at the larger of its natural size and the room")
    func extentIsTheLarger() {
        #expect(Overflow.extent(room: 900, natural: 608) == 900)
        #expect(Overflow.extent(room: 608, natural: 608) == 608)
        #expect(Overflow.extent(room: 300, natural: 608) == 608)
        // No natural size: the content fills the room.
        #expect(Overflow.extent(room: 300, natural: 0) == 300)
    }

    @Test("a pane scrolls only while its room is smaller than its content")
    func scrollsOnlyWhenSmaller() {
        #expect(Overflow.scrolls(room: 300, natural: 608))
        #expect(!Overflow.scrolls(room: 608, natural: 608))
        #expect(!Overflow.scrolls(room: 900, natural: 608))
        #expect(!Overflow.scrolls(room: 300, natural: 0))
    }

    @Test("a room or natural size that is not a finite positive number draws at the natural size", arguments: [
        0, -10, Double.nan, Double.infinity,
    ])
    func unsettledRoom(room: Double) {
        #expect(Overflow.extent(room: room, natural: 608) == 608)
        #expect(Overflow.extent(room: 500, natural: .nan) == 500)
        #expect(Overflow.extent(room: 500, natural: -5) == 500)
    }
}
