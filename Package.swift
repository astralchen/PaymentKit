// swift-tools-version: 6.2
// swift-tools-version 声明构建此包所需的最低 Swift 版本。

import PackageDescription

let package = Package(
    name: "PaymentKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PaymentKit", targets: ["PaymentKit"]),
        .executable(
            name: "paymentkit-offer-signer",
            targets: ["PaymentKitOfferSigner"]
        ),
    ],
    targets: [
        .target(
            name: "PaymentKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("NonisolatedNonsendingByDefault"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "PaymentKitTests",
            dependencies: ["PaymentKit"]
        ),
        .target(
            name: "PaymentKitOfferSigning",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "PaymentKitOfferSigner",
            dependencies: ["PaymentKitOfferSigning"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "PaymentKitOfferSigningTests",
            dependencies: ["PaymentKitOfferSigning"]
        ),
    ]
)
