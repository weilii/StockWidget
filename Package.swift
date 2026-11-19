// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockWidget",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StockWidget", targets: ["StockWidget"]),
        .executable(name: "StockWidgetCheck", targets: ["StockWidgetCheck"])
    ],
    targets: [
        .target(name: "MarketCore"),
        .executableTarget(name: "StockWidget", dependencies: ["MarketCore"]),
        .executableTarget(name: "StockWidgetCheck", dependencies: ["MarketCore"])
    ],
    swiftLanguageModes: [.v5]
)
