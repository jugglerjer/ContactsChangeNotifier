// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ContactsChangeNotifier",
    platforms: [
        .iOS(.v15),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ContactsChangeNotifier", targets: ["ContactsChangeNotifier", "ContactStoreChangeHistory"]),
    ],
    targets: [
        .target(
            name: "ContactStoreChangeHistory"
        ),
        .target(
            name: "ContactsChangeNotifier",
            dependencies: ["ContactStoreChangeHistory"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ContactsChangeNotifierTests",
            dependencies: ["ContactsChangeNotifier"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
