// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FluxLLM",
    platforms: [
          .macOS(.v15)
      ],
    dependencies: [
          .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
          .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0"),
      ],
    targets: [
          // Core library: proxy, telemetry, UI. Tested via @testable import.
          .target(
            name: "FluxLLM",
            dependencies: [
                  .product(name: "NIO", package: "swift-nio"),
                  .product(name: "NIOHTTP1", package: "swift-nio"),
                  .product(name: "NIOHTTP2", package: "swift-nio-http2"),
              ],
            path: "Sources/FluxLLM",
            resources: [
                  .copy("Resources/Branding"),
              ]
          ),
          // Executable target: the @main app entry point. Kept separate from the
          // library so the test target can link the core without a duplicate _main.
          .executableTarget(
            name: "FluxLLMApp",
            dependencies: ["FluxLLM"],
            path: "Sources/FluxLLMApp"
          ),
          // Control pipes, synthetic history and drawing experiments are linked
          // only by performance executables and tests, never the desktop app.
          .target(
            name: "FluxLLMPerformanceSupport",
            dependencies: ["FluxLLM"],
            path: "Sources/FluxLLMPerformanceSupport"
          ),
          .executableTarget(
            name: "FluxLLMPerformanceApp",
            dependencies: ["FluxLLM", "FluxLLMPerformanceSupport"],
            path: "Sources/FluxLLMPerformanceApp"
          ),
          .executableTarget(
            name: "FluxLLMResourceCollector",
            dependencies: ["FluxLLM", "FluxLLMPerformanceSupport"],
            path: "Sources/FluxLLMResourceCollector"
          ),
          // Opt-in, inherited-pipe drawing isolation. It starts no application
          // services and is never part of the normal FluxLLM app lifecycle.
          .executableTarget(
            name: "FluxLLMDrawingProbe",
            dependencies: ["FluxLLM", "FluxLLMPerformanceSupport"],
            path: "Sources/FluxLLMDrawingProbe"
          ),
          .testTarget(
            name: "FluxLLMTests",
            dependencies: ["FluxLLM", "FluxLLMPerformanceSupport"],
            path: "Tests/FluxLLMTests"
          ),
      ]
)
