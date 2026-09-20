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
            dependencies: [
                  "FluxLLM",
                  .product(name: "NIO", package: "swift-nio"),
              ],
            path: "Sources/FluxLLMApp"
          ),
          .testTarget(
            name: "FluxLLMTests",
            dependencies: ["FluxLLM"],
            path: "Tests/FluxLLMTests"
          ),
      ]
)
