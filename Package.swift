// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chroma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChromaCore", targets: ["ChromaCore"]),
        .executable(name: "Chroma", targets: ["ChromaApp"]),
    ],
    targets: [
        .target(name: "ChromaCore"),
        .executableTarget(name: "ChromaApp", dependencies: ["ChromaCore"]),
        .testTarget(name: "ChromaCoreTests", dependencies: ["ChromaCore"]),
        .testTarget(name: "ChromaAppTests", dependencies: ["ChromaApp", "ChromaCore"]),
    ]
)
