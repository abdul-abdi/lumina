import Foundation
import Testing
@testable import Lumina

@Test func diskCloneCreatesDirectory() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let imagesDir = tempDir.appendingPathComponent("images/default")
    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

    // Create a fake rootfs.img
    let fakeImage = imagesDir.appendingPathComponent("rootfs.img")
    try Data("fake image content".utf8).write(to: fakeImage)

    let clone = try DiskClone.create(from: fakeImage, runsDir: runsDir)

    #expect(FileManager.default.fileExists(atPath: clone.rootfs.path))
    #expect(FileManager.default.fileExists(atPath: clone.pidFile.path))

    // Read PID file — should contain our PID
    let pidStr = try String(contentsOf: clone.pidFile, encoding: .utf8)
    #expect(pidStr == "\(ProcessInfo.processInfo.processIdentifier)")

    // Cleanup
    clone.remove()
    #expect(!FileManager.default.fileExists(atPath: clone.directory.path))

    try FileManager.default.removeItem(at: tempDir)
}

@Test func diskCloneCleanOrphans() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let orphanDir = runsDir.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)

    // Write a PID file with a PID that definitely doesn't exist (99999999)
    let pidFile = orphanDir.appendingPathComponent(".pid")
    try Data("99999999".utf8).write(to: pidFile)

    // Also write a fake rootfs so the directory looks like a real clone
    try Data("fake".utf8).write(to: orphanDir.appendingPathComponent("rootfs.img"))

    let removed = DiskClone.cleanOrphans(runsDir: runsDir)
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: orphanDir.path))

    try FileManager.default.removeItem(at: tempDir)
}

/// A run directory that exists with no `.pid` yet is a clone in flight, not an
/// orphan. `create()` used to write the PID *after* copying the rootfs, so the
/// whole ~1GB copy was a window in which a concurrent `lumina run` — every one
/// of which sweeps orphans at startup and atexit — deleted the directory out
/// from under the process filling it. Roughly 1 in 15 concurrent boots died
/// with `rootfs.img doesn't exist` or `.pid doesn't exist`.
@Test func cleanOrphansSpareFreshDirectoryWithNoPidYet() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let inFlight = runsDir.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: inFlight, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    #expect(DiskClone.cleanOrphans(runsDir: runsDir) == 0)
    #expect(FileManager.default.fileExists(atPath: inFlight.path))
}

/// A clone under construction must survive a sweep running concurrently with
/// it — the condition that actually broke concurrent boots. Ordering can't be
/// asserted from timestamps: `copyItem` carries the source file's creation
/// date over, so the clone always looks older than the PID written before it.
@Test func cleanOrphansSparesCloneUnderConstruction() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let imagesDir = tempDir.appendingPathComponent("images/default")
    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fakeImage = imagesDir.appendingPathComponent("rootfs.img")
    try Data(repeating: 0x41, count: 8 * 1024 * 1024).write(to: fakeImage)

    let clone = try DiskClone.create(from: fakeImage, runsDir: runsDir)
    #expect(DiskClone.cleanOrphans(runsDir: runsDir) == 0)
    #expect(FileManager.default.fileExists(atPath: clone.rootfs.path))
    #expect(FileManager.default.fileExists(atPath: clone.pidFile.path))
}

/// An orphan old enough to be past the in-flight grace period is still removed.
@Test func cleanOrphansRemovesOldDirectoryWithNoPid() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let stale = runsDir.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let old = Date().addingTimeInterval(-(DiskClone.newCloneGracePeriod + 60))
    try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: stale.path)

    #expect(DiskClone.cleanOrphans(runsDir: runsDir) == 1)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}

@Test func diskCloneSkipsLiveProcess() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-test-\(UUID().uuidString)")
    let runsDir = tempDir.appendingPathComponent("runs")
    let liveDir = runsDir.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)

    // Write OUR PID — this process is alive
    let pidFile = liveDir.appendingPathComponent(".pid")
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: pidFile)
    try Data("fake".utf8).write(to: liveDir.appendingPathComponent("rootfs.img"))

    let removed = DiskClone.cleanOrphans(runsDir: runsDir)
    #expect(removed == 0)
    #expect(FileManager.default.fileExists(atPath: liveDir.path))

    try FileManager.default.removeItem(at: tempDir)
}
