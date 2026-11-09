import Foundation
import Testing
@testable import LuminaBootable

@Suite struct VMSnapshotTests {
    @Test func takeRestoreAndDelete() throws {
        let bundle = try VMBundle.create(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("LuminaSnapshots-\(UUID().uuidString)"),
            name: "snap", osFamily: .linux, osVariant: "debian-12",
            memoryBytes: 1 << 30, cpuCount: 1, diskBytes: 1 << 30
        )
        try Data("before".utf8).write(to: bundle.primaryDiskURL)
        try Data("vars".utf8).write(to: bundle.efiVarsURL)
        let snapshot = try bundle.takeSnapshot(at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(bundle.snapshots.map(\.url.lastPathComponent) == [snapshot.url.lastPathComponent])

        try Data("after".utf8).write(to: bundle.primaryDiskURL)
        try bundle.restore(snapshot)
        #expect(try String(contentsOf: bundle.primaryDiskURL, encoding: .utf8) == "before")
        #expect(try String(contentsOf: bundle.efiVarsURL, encoding: .utf8) == "vars")

        try bundle.deleteSnapshot(snapshot)
        #expect(bundle.snapshots.isEmpty)
    }
}
