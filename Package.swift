// swift-tools-version:5.9
import PackageDescription

// PromiseCore holds all domain logic: entities, deterministic date interpretation,
// rule-based extraction fallback, validation, reminder policy, persistence and use cases.
// It depends only on Foundation so it builds and tests on macOS, iOS and Linux.
// The SwiftUI app (App/) links it and adds Apple-only adapters (Foundation Models,
// Speech, App Intents, UserNotifications, StoreKit).
let package = Package(
    name: "PromiseTracker",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PromiseCore", targets: ["PromiseCore"]),
    ],
    targets: [
        .target(name: "PromiseCore", path: "Sources/PromiseCore"),
        .testTarget(name: "PromiseCoreTests", dependencies: ["PromiseCore"], path: "Tests/PromiseCoreTests"),
    ]
)
