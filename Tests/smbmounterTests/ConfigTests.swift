import XCTest
@testable import smbmounter

final class ConfigTests: XCTestCase {
    private let sample = """
    # comment line
    [defaults]
    mount_options       = ["soft", "nodev", "nosuid", "noowners"]
    probe_interval_sec  = 60
    probe_timeout_sec   = 5
    recover_backoff_sec = [2, 5, 15, 30, 60]   # capped retry schedule
    idle_unmount_min    = 0
    mount_at_startup    = true
    create_keepalive    = true
    keepalive_filename  = ".smbmounter-keepalive"
    log_level           = "info"

    [[mount]]
    name        = "mammoth"
    server      = "mammoth"
    share       = "mammoth"
    mountpoint  = "/mammoth"
    username    = "floof"

    [[mount]]
    name        = "backup"
    server      = "mammoth"
    share       = "Backup"
    mountpoint  = "/Volumes/mammoth-backup"
    username    = "floof"
    idle_unmount_min = 30
    probe_interval_sec = 30
    """

    func testParsesDefaultsAndMounts() throws {
        let config = try Config.parse(sample)
        XCTAssertEqual(config.defaults.probeIntervalSec, 60)
        XCTAssertEqual(config.defaults.recoverBackoffSec, [2, 5, 15, 30, 60])
        XCTAssertEqual(config.defaults.mountOptions, ["soft", "nodev", "nosuid", "noowners"])
        XCTAssertEqual(config.mounts.count, 2)
    }

    func testPerMountOverrideAndDefaultInheritance() throws {
        let config = try Config.parse(sample)
        let mammoth = try XCTUnwrap(config.mounts.first { $0.name == "mammoth" })
        let backup = try XCTUnwrap(config.mounts.first { $0.name == "backup" })

        // mammoth inherits defaults
        XCTAssertEqual(mammoth.idleUnmountMin, 0)
        XCTAssertEqual(mammoth.probeIntervalSec, 60)
        // backup overrides
        XCTAssertEqual(backup.idleUnmountMin, 30)
        XCTAssertEqual(backup.probeIntervalSec, 30)
        // but still inherits non-overridden defaults
        XCTAssertEqual(backup.probeTimeoutSec, 5)
        XCTAssertEqual(backup.mountOptions, ["soft", "nodev", "nosuid", "noowners"])
    }

    func testKeepalivePath() throws {
        let config = try Config.parse(sample)
        let mammoth = try XCTUnwrap(config.mounts.first { $0.name == "mammoth" })
        XCTAssertEqual(mammoth.keepalivePath, "/mammoth/.smbmounter-keepalive")
    }

    func testTrailingCommentAfterArrayIsStripped() throws {
        let config = try Config.parse(sample)
        // If the comment weren't stripped, the array parse would have failed.
        XCTAssertEqual(config.defaults.recoverBackoffSec.last, 60)
    }

    func testValidConfigPassesStaticValidation() throws {
        let config = try Config.parse(sample)
        XCTAssertNoThrow(try config.validateStatic())
    }

    // MARK: Validation failures

    func testDuplicateNameRejected() throws {
        let toml = sample + "\n[[mount]]\nname=\"mammoth\"\nserver=\"x\"\nshare=\"y\"\nmountpoint=\"/z\"\nusername=\"u\"\n"
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic())
    }

    func testMissingSoftOptionRejected() throws {
        let toml = """
        [[mount]]
        name="m"
        server="s"
        share="sh"
        mountpoint="/m"
        username="u"
        mount_options=["nodev","nosuid"]
        """
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic()) { error in
            XCTAssertTrue("\(error)".contains("soft"))
        }
    }

    func testPasswordInOptionsRejected() throws {
        let toml = """
        [[mount]]
        name="m"
        server="s"
        share="sh"
        mountpoint="/m"
        username="u"
        mount_options=["soft","password=hunter2"]
        """
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic())
    }

    func testNegativeIdleRejected() throws {
        let toml = """
        [[mount]]
        name="m"
        server="s"
        share="sh"
        mountpoint="/m"
        username="u"
        idle_unmount_min=-5
        """
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic())
    }

    func testIllegalNameRejected() throws {
        let toml = """
        [[mount]]
        name="bad name!"
        server="s"
        share="sh"
        mountpoint="/m"
        username="u"
        """
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic())
    }

    func testRelativeMountpointRejected() throws {
        let toml = """
        [[mount]]
        name="m"
        server="s"
        share="sh"
        mountpoint="relative/path"
        username="u"
        """
        let config = try Config.parse(toml)
        XCTAssertThrowsError(try config.validateStatic())
    }

    func testUnknownTableRejected() {
        XCTAssertThrowsError(try Config.parse("[bogus]\nx=1\n"))
    }

    func testKeyBeforeTableRejected() {
        XCTAssertThrowsError(try Config.parse("x = 1\n"))
    }

    func testMissingRequiredFieldRejected() {
        XCTAssertThrowsError(try Config.parse("[[mount]]\nname=\"m\"\n"))
    }

    /// The example config we ship must always parse and pass static validation.
    func testShippedExampleConfigIsValid() throws {
        // .../Tests/smbmounterTests/ConfigTests.swift -> package root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // smbmounterTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // root
        let example = root.appendingPathComponent("config.example.toml").path
        let config = try Config.load(path: example)
        XCTAssertNoThrow(try config.validateStatic())
        XCTAssertTrue(config.mounts.contains { $0.name == "mammoth" })
    }
}
