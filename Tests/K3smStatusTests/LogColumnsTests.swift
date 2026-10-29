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

struct LogColumnsTests {
    @Test("the longest line is counted across appends, a line split between them included")
    func longestAcrossAppends() {
        var columns = LogColumns()
        columns.append("abc\nabcdef")
        #expect(columns.longest == 6)
        #expect(columns.current == 6)
        columns.append("ghi\nx")
        #expect(columns.longest == 9)
        #expect(columns.current == 1)
        columns.append("\r\n")
        #expect(columns.current == 0)
        #expect(columns == LogColumns("abc\nabcdefghi\nx\r\n"))
    }

    @Test("a tab moves to the next stop of eight and a wide character takes two columns")
    func tabsAndWideCharacters() {
        #expect(LogColumns("a\tb").longest == 9)
        #expect(LogColumns("\t\t").longest == 16)
        #expect(LogColumns("日本").longest == 4)
        #expect(LogColumns("é").longest == 1)
    }

    @Test("the content width covers the longest line and both insets")
    func contentWidth() {
        let expected: Double = 28 + 24 + 10 + 1
        #expect(LogColumns("abcd").width(advance: 7, inset: 12, padding: 5) == expected)
        #expect(LogColumns().width(advance: 7, inset: 0, padding: 0) == 1)
    }
}
