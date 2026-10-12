// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "ProxiWidgets", platforms: [.macOS(.v14)],
                      products: [.library(name: "ProxiWidgets", targets: ["ProxiWidgets"])],
                      targets: [.target(name: "ProxiWidgets"), .testTarget(name: "ProxiWidgetsTests", dependencies: ["ProxiWidgets"])])
