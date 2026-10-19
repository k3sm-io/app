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

// The Swift half of hack/release-index-differential.sh: it writes the seeded
// mutants of a release index into a directory and prints this decoder's
// verdict on each, one line per mutant, for comparison with k3sm's.
//
// usage: main <index.json> <count> <seed> <out-dir>

import Foundation

let args = CommandLine.arguments
guard args.count == 5, let count = Int(args[2]), let seed = UInt64(args[3]),
      let golden = FileManager.default.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("usage: main <index.json> <count> <seed> <out-dir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[4])
for (i, mutant) in ReleaseIndexMutator.mutants(of: Array(golden), count: count, seed: seed).enumerated() {
    let name = String(format: "%05d.json", i)
    try Data(mutant).write(to: out.appendingPathComponent(name))
    print(name + "\t" + ReleaseIndexMutator.verdict(mutant))
}
