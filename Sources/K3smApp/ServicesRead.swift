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
import K3smStatus

/// ServicesRead is the Services tab's read: the service and ingress list,
/// then, only when that list succeeded, the EndpointSlices, each through
/// `TabLoader.run` (the list deadline and `OutputLimit.list`). The list
/// decides the tab's result; the slices only add each row's ready count
/// (`ServicesList.tabResult(listExit:listStdout:endpoints:)`), so a slice
/// read that fails, is killed or runs past the limit leaves the counts
/// "not reported".
enum ServicesRead {
    nonisolated static func read(environment: [String: String]) async -> TabResult<[ServiceRow]> {
        let list = await TabLoader<[ServiceRow]>.run(arguments: K3smCLI.servicesArguments, environment: environment)
        guard case .exited(let status, let stdout) = list, status == 0, !Task.isCancelled else {
            return TabLoader<[ServiceRow]>.result(of: list, what: "service list", decode: ServicesList.tabResult(exitCode:stdout:))
        }
        var endpoints: (exit: Int32, stdout: Data)?
        if case .exited(let code, let out) = await TabLoader<[ServiceRow]>.run(
            arguments: K3smCLI.endpointSlicesArguments, environment: environment) {
            endpoints = (code, out)
        }
        return ServicesList.tabResult(listExit: status, listStdout: stdout, endpoints: endpoints)
    }
}
