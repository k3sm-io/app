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

import K3smInstall
import K3smStatus

/// The decoder (K3smStatus) cannot import the signer policy (K3smInstall
/// depends on K3smStatus), so each declares the context string; this holds the
/// two equal.
@Suite("release index context")
struct ReleaseIndexContextTests {
    @Test func decoderAndSignerPolicyAgreeOnTheContext() {
        #expect(ReleaseIndex.context == IndexSignerPolicy.contextString)
    }
}
