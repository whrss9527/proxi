// swift-tools-version: 5.9
import PackageDescription

// Proxi：原生的 macOS 菜单栏代理开关。用 swift build 编译，Scripts/build-app.sh 组装成 .app。
// ProxiEngine 是可选扩展「代理引擎」，单独的程序（Proxi Engine.app），不打包进 Proxi.app，
// 由用户在 Proxi 的「设置 → 扩展」里开启后下载（见 docs/extension.md）。
let package = Package(
    name: "Proxi",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Packages/ProxiProcess")],
    targets: [
        .executableTarget(
            name: "Proxi",
            dependencies: ["ProxiProcess"],
            path: "Sources/Proxi"
        ),
        .executableTarget(
            name: "ProxiEngine",
            dependencies: ["ProxiProcess"],
            path: "Sources/ProxiEngine"
        ),
        .testTarget(
            name: "ProxiTests",
            dependencies: ["Proxi"],
            path: "Tests/ProxiTests"
        ),
        .testTarget(
            name: "ProxiEngineTests",
            dependencies: ["ProxiEngine"],
            path: "Tests/ProxiEngineTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
