// swift-tools-version:6.0
import PackageDescription

// PushPipelineKit is a library-only package: it deliberately declares no
// executable product or target. The runnable demo lives in a separate
// repository (push-pipeline-kit-demo-app) that consumes this package as a
// remote dependency, the same way any external consumer would.
let package = Package(
    name: "PushPipelineKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PushPipelineKit", targets: ["PushPipelineKit"])
    ],
    targets: [
        .target(name: "PushPipelineKit"),
        .testTarget(
            name: "PushPipelineKitTests",
            dependencies: ["PushPipelineKit"]
        ),
    ]
)
