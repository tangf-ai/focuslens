// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FocusLens", targets: ["FocusLens"])],
    targets: [
        .executableTarget(name: "FocusLens")
    ]
)
