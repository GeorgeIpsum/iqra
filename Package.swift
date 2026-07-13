// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Iqra",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IqraCore", targets: ["IqraCore"]),
        .library(name: "IqraLibrary", targets: ["IqraLibrary"]),
        .library(name: "IqraReader", targets: ["IqraReader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "IqraCore"),
        .target(
            name: "IqraLibrary",
            dependencies: [
                "IqraCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "IqraReader",
            dependencies: ["IqraCore"],
            resources: [
                .copy("Vendor"),
                .copy("Resources"),
            ]
        ),
        .testTarget(name: "IqraCoreTests", dependencies: ["IqraCore"]),
        .testTarget(name: "IqraLibraryTests", dependencies: ["IqraLibrary"]),
        .testTarget(name: "IqraReaderTests", dependencies: [
            "IqraReader",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
    ]
)
