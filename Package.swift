// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ON1Editor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ON1Editor", targets: ["ON1Editor"])],
    targets: [.executableTarget(name: "ON1Editor", path: "Sources/ON1Editor")]
)
