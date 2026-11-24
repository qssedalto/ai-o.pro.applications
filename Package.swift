// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AIOStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIOStudio", targets: ["AIOStudio"])],
    targets: [.target(name: "MallCore"), .executableTarget(name: "AIOStudio", dependencies: ["MallCore"]), .testTarget(name: "MallCoreTests", dependencies: ["MallCore"])]
)
