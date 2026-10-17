// swift-tools-version: 6.0
// TableScoreKit : domaine métier pur (modèles, validation, moteur de score) de TableScore.
// Foundation uniquement, aucune dépendance externe, aucun accès réseau ni E/S.
import PackageDescription

let package = Package(
    name: "TableScoreKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "TableScoreKit", targets: ["TableScoreKit"])
    ],
    targets: [
        .target(name: "TableScoreKit"),
        .testTarget(name: "TableScoreKitTests", dependencies: ["TableScoreKit"])
    ],
    swiftLanguageModes: [.v6]
)
