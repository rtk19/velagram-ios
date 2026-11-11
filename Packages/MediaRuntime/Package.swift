// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func binary(_ name: String, url: String, checksum: String) -> Target {
    let path = "Artifacts/\(name).xcframework"
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).appendingPathComponent("Info.plist").path) { return .binaryTarget(name: name, path: path) }
    return .binaryTarget(name: name, url: url, checksum: checksum)
}


// Exact upstream binary URLs and SHA-256 checksums, copied from the pinned
// Swiftgram and VideoLAN manifests. No build-time source submodules are needed.
let package = Package(
    name: "VelagramMediaRuntime",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TDLibFramework", targets: ["TDLibFrameworkWrapper"]),
        .library(name: "VLCKit", targets: ["VLCKit"])
    ],
    targets: [
        .target(name: "TDLibFrameworkWrapper", dependencies: ["TDLibFramework"], linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        binary("TDLibFramework", url: "https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.69-6126ecae/TDLibFramework.zip", checksum: "97c34692d08d1bde70e73c97d2ac6afae1c0009416018509c78a7d939ebdc00c"),
        binary("VLCKit", url: "https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip", checksum: "f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb")
    ]
)
