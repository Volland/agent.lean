// swift-tools-version:5.9
// Swift binding of agent.lean over its C ABI (c/agent.h), through Swift's native C interop.
//
// The C library comes from one of two places, both exposed as the Clang module `AgentLeanC`:
//
// * `AgentLeanC.xcframework` next to this file (built by scripts/build_xcframework.sh): static
//   libraries for macOS, iOS, the iOS simulator and Mac Catalyst. Used whenever it exists.
// * Otherwise, or when AGENTLEAN_LINK=host is set, the host build of the bundle at
//   ../../build/host/libagentlean.a (`cmake -S bundle/out -B build/host && cmake --build build/host`),
//   for fast macOS iteration. AGENTLEAN_HOST_LIB_DIR overrides that directory. This path uses an
//   unsafe linker flag, so it only works when this package is the root package (e.g. `swift test`).
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: Context.packageDirectory)
let xcframework = packageDir.appendingPathComponent("AgentLeanC.xcframework")
let env = ProcessInfo.processInfo.environment
let useHostLib = env["AGENTLEAN_LINK"] == "host"
  || (env["AGENTLEAN_LINK"] != "xcframework" && !FileManager.default.fileExists(atPath: xcframework.path))

let cTarget: Target
if useHostLib {
  let libDir = env["AGENTLEAN_HOST_LIB_DIR"]
    ?? packageDir.appendingPathComponent("../../build/host").standardized.path
  cTarget = .target(
    name: "AgentLeanC",
    path: "Sources/AgentLeanCHost",
    publicHeadersPath: "include",
    // By full path: `-lagentlean` would resolve to SwiftPM's own libAgentLean.a on a
    // case-insensitive file system.
    linkerSettings: [.unsafeFlags(["-Xlinker", libDir + "/libagentlean.a"]), .linkedLibrary("c++")]
  )
} else {
  cTarget = .binaryTarget(name: "AgentLeanC", path: "AgentLeanC.xcframework")
}

let package = Package(
  name: "AgentLean",
  platforms: [.macOS(.v13), .iOS(.v15), .macCatalyst(.v16)],
  products: [
    .library(name: "AgentLean", targets: ["AgentLean"])
  ],
  targets: [
    cTarget,
    .target(
      name: "AgentLean",
      dependencies: ["AgentLeanC"],
      linkerSettings: [.linkedLibrary("c++")]
    ),
    .testTarget(
      name: "AgentLeanTests",
      dependencies: ["AgentLean"]
    ),
  ]
)
