// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gemma4Swift",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "Gemma4Swift", targets: ["Gemma4Swift"]),
        .executable(name: "gemma4-cli", targets: ["Gemma4CLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        // Pinned to an exact revision (was `branch: "main"`): the app pins the same
        // SHA, and SPM forbids two different revision-based requirements for one
        // package. Keep this in lockstep with `mlx-swift-lm` in the app's project.yml.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "a47894a1e7e963b24bd48c030f5fc1d1627e60e9"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/VincentGourbin/swift-mlx-profiler", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "Gemma4Swift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
            ]
        ),
        .executableTarget(
            name: "Gemma4CLI",
            dependencies: [
                "Gemma4Swift",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
            ]
        ),
        .testTarget(
            name: "Gemma4SwiftTests",
            dependencies: [
                "Gemma4Swift",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
    ]
)
