// swift-tools-version:5.9
// 判定ロジックだけを Mac で `swift test` するためのパッケージ。アプリのビルドは project.yml（XcodeGen）で行う。
// ファイルは POC01/ に置いたまま、UIKit や AVFoundation に依存しない2ファイルだけをライブラリにする。
import PackageDescription

let package = Package(
    name: "POC01HitDetection",
    targets: [
        .target(
            name: "HitDetectionCore",
            path: "POC01",
            sources: ["DetectionConfig.swift", "HitDetector.swift"]
        ),
        .testTarget(
            name: "HitDetectionCoreTests",
            dependencies: ["HitDetectionCore"],
            path: "Tests/HitDetectionCoreTests",
            // フィクスチャは #filePath から直接読むので、リソースとしては扱わない
            exclude: ["Fixtures"]
        ),
    ]
)
