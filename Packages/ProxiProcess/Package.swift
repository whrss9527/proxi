// swift-tools-version: 5.9
import PackageDescription

// 主程序和扩展共用的进程执行层，独立运行 Linux/macOS 生命周期测试。
let package = Package(
    name: "ProxiProcess",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProxiProcess", targets: ["ProxiProcess"])],
    targets: [
        .target(name: "ProxiProcess"),
        .testTarget(name: "ProxiProcessTests", dependencies: ["ProxiProcess"]),
    ]
)
