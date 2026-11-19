// swift-tools-version: 6.0
//
// This file exists only so Dependabot can see the Swift packages of the
// app and keep Package.resolved current. It is never built. The app is
// built from project.yml (and sparkle.yml) by XcodeGen: the packages and
// version ranges below must say the same as those two files, and
// tests/test-macos-package-pins.sh fails when they do not. See
// macos/DECISIONS.md, "Swift package pins".
import PackageDescription

let package = Package(
    name: "BenchBarPackagePins",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: []
)
