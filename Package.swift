// swift-tools-version:6.0
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

import PackageDescription

let package = Package(
    name: "K3smApp",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "K3smStatus", targets: ["K3smStatus"]),
        .library(name: "K3smInstall", targets: ["K3smInstall"]),
        .executable(name: "K3smApp", targets: ["K3smApp"]),
        // The read-only MCP server the bundle ships at Contents/MacOS/k3sm-mcp.
        .executable(name: "k3sm-mcp", targets: ["K3smMCPServer"]),
    ],
    targets: [
        .target(name: "K3smStatus"),
        .target(name: "K3smInstall", dependencies: ["K3smStatus"]),
        // Runs the installed CLI after its trust check: shared by the app
        // and the MCP server, so both read k3sm the same way.
        .target(name: "K3smHost", dependencies: ["K3smStatus", "K3smInstall"]),
        .target(name: "K3smMCP", dependencies: ["K3smStatus"]),
        .executableTarget(name: "K3smApp", dependencies: ["K3smStatus", "K3smInstall", "K3smHost"]),
        .executableTarget(name: "K3smMCPServer", dependencies: ["K3smMCP", "K3smHost", "K3smInstall", "K3smStatus"]),
        .testTarget(
            name: "K3smStatusTests",
            dependencies: ["K3smStatus", "K3smMCP"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "K3smInstallTests", dependencies: ["K3smInstall", "K3smStatus"], resources: [.copy("Fixtures")]),
        .testTarget(name: "K3smHostTests", dependencies: ["K3smHost", "K3smStatus"]),
        // Drives the console's split views in a real window: the few app
        // behaviours that only AppKit and SwiftUI together decide.
        .testTarget(name: "K3smAppTests", dependencies: ["K3smApp", "K3smInstall", "K3smStatus"]),
    ]
)
