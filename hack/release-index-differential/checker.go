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

// The Go half of hack/release-index-differential.sh: it prints k3sm's
// ParseReleaseIndex verdict on every file in a directory, in name order, in
// the format the Swift half prints.
//
// usage: go run . <dir>
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"k3sm.io/k3sm/pkg/update"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: checker <dir>")
		os.Exit(2)
	}
	names, err := filepath.Glob(filepath.Join(os.Args[1], "*.json"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	sort.Strings(names)
	for _, path := range names {
		raw, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		verdict := "refuse"
		if ix, err := update.ParseReleaseIndex(raw); err == nil {
			verdict = strings.Join([]string{"accept", ix.Schema, ix.Context, ix.IssuedAt, ix.Tag, ix.MinimumMacOS,
				ix.MinimumSupportedTag,
				ix.App.BundleID, ix.App.ShortVersion, ix.App.Image.Name, ix.App.Image.URL,
				ix.App.Image.SHA256, fmt.Sprint(ix.App.Image.Size),
				ix.K3sm.Archive, ix.K3sm.ArchiveSHA256, ix.K3sm.PayloadManifestSHA256}, "\t")
		}
		fmt.Println(filepath.Base(path) + "\t" + verdict)
	}
}
