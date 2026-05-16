// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Starmania",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/chicio/ID3TagEditor.git", from: "4.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Starmania",
            dependencies: ["ID3TagEditor", "SwiftSoup"]
        ),
    ]
)
