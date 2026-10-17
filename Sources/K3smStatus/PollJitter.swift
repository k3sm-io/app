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

/// PollJitter spreads a poll's wait so the app's timers do not fire in step
/// with each other or with another Mac's copy of the app: a wait grows by up
/// to a fifth of itself and never shrinks, so no poll runs more often than
/// its profile says and Low power stays at least twice Normal. The caller
/// draws one unit per completed wait (`draw()`) and passes it in; the
/// spread itself is pure, after `Flap.rest(unit:)`.
public enum PollJitter {
    /// The most a wait grows by, as a fraction of it.
    public static let maxFraction = 0.2

    /// One random unit in 0...1, drawn once per wait.
    public static func draw() -> Double {
        Double.random(in: 0...1)
    }

    /// `base` grown by `unit` (clamped to 0...1; not a number is 0) times
    /// `maxFraction`: `base` at 0, `base` and a fifth at 1. A wait that is
    /// zero or negative is returned as it is.
    public static func spread(_ base: Duration, unit: Double) -> Duration {
        guard base > .zero else { return base }
        let clamped = unit.isNaN ? 0 : min(max(unit, 0), 1)
        let grown = base + base * (clamped * maxFraction)
        return max(grown, base)
    }
}
