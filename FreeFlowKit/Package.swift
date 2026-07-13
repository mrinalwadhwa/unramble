// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FreeFlowKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FreeFlowKit",
            targets: ["FreeFlowKit"]
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
            name: "FreeFlowKit",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/FreeFlowKit"
        ),
        .testTarget(
            name: "FreeFlowKitTests",
            dependencies: ["FreeFlowKit"],
            path: "Tests/FreeFlowKitTests"
        ),
    ]
)
