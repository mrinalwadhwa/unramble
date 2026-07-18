// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "UnrambleKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "UnrambleKit",
            targets: ["UnrambleKit"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            exact: "3.31.3"),
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "UnrambleKit",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/UnrambleKit"
        ),
        .target(
            name: "UnrambleKitTestSupport",
            dependencies: ["UnrambleKit"],
            path: "Tests/UnrambleKitTestSupport"
        ),
        .testTarget(
            name: "UnrambleKitTests",
            dependencies: ["UnrambleKit", "UnrambleKitTestSupport"],
            path: "Tests/UnrambleKitTests"
        ),
        .testTarget(
            name: "UnrambleKitOSTests",
            dependencies: ["UnrambleKit", "UnrambleKitTestSupport"],
            path: "Tests/UnrambleKitOSTests"
        ),
    ]
)
