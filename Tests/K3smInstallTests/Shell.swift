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

import Foundation

/// Runs /bin/sh with `arguments` and returns its exit status and standard
/// output. The tests use it to prove that quoted words reach the shell as
/// data; it never runs anything privileged.
func shell(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Hostile strings every quoting test runs through.
let hostileStrings: [String] = [
    "",
    "plain",
    "two words",
    "'",
    "''",
    "it's",
    "$(id)",
    "`id`",
    "${HOME}",
    "\"; rm -rf / #",
    "a\nb",
    "*",
    "~root",
    "back\\slash",
    "-n",
    "; echo pwned",
    "| cat /etc/passwd",
    "&& touch /tmp/pwned",
    "k3sm 💥 ünïcode",
]
