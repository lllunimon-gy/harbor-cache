// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Harbor", targets: ["Harbor", "HarborObjC"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HarborObjC", publicHeadersPath: "include"),
        .target(name: "Harbor", dependencies: ["HarborObjC", "CSQLite"]),

        .testTarget(name: "HarborTests", dependencies: ["Harbor"])
    ]
)
