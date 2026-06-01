// swift-tools-version:5.9
//
// We pin to the Swift 5.9 tools version (and therefore the Swift 5 language
// mode) deliberately. smbmounter is a GCD/DispatchQueue-based daemon with a lot
// of shared mutable state guarded by per-mount serial queues and locks. Swift 6's
// strict concurrency checking fights that design without adding real safety here,
// so we stay in the Swift 5 language mode. (This is one of the "pick the simpler
// option and document why" decisions from the spec.)
//
// We also intentionally take ZERO external dependencies. The spec allows
// swift-argument-parser and TOMLKit, but a root LaunchDaemon benefits from being
// auditable and buildable with no network fetch and no third-party code in the
// trust path. The CLI is a handful of subcommands (trivial to hand-parse) and the
// config is a small, fixed TOML schema (a focused hand-rolled parser covers it).
import PackageDescription

let package = Package(
    name: "smbmounter",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "smbmounter",
            path: "Sources/smbmounter"
        ),
        .testTarget(
            name: "smbmounterTests",
            dependencies: ["smbmounter"],
            path: "Tests/smbmounterTests"
        ),
    ]
)
