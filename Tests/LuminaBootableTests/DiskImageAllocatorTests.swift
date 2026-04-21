// Tests/LuminaBootableTests/DiskImageAllocatorTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct DiskImageAllocatorTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaDiskImageAllocatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    @Test func allocate_createsFileOfExactLogicalSize() throws {
        let path = tmp.appendingPathComponent("disk.img")
        try DiskImageAllocator.allocate(at: path, logicalSize: 64 * 1024 * 1024) // 64 MB
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        #expect(fileSize == 64 * 1024 * 1024)
    }

    @Test func allocate_createsSparseFile() throws {
        let path = tmp.appendingPathComponent("sparse.img")
        // 16 GB logical — if not sparse, this would exhaust CI disk fast.
        try DiskImageAllocator.allocate(at: path, logicalSize: 16 * 1024 * 1024 * 1024)
        let rsrc = try path.resourceValues(forKeys: [.fileAllocatedSizeKey])
        let allocated = rsrc.fileAllocatedSize ?? Int.max
        // Expect near-zero physical bytes. Allow 1 MB for filesystem metadata.
        #expect(allocated < 1024 * 1024, "expected sparse allocation, got \(allocated) bytes")
    }

    @Test func allocate_rejectsExistingFile() throws {
        let path = tmp.appendingPathComponent("exists.img")
        FileManager.default.createFile(atPath: path.path, contents: Data([0x42]))
        #expect(throws: DiskImageAllocator.Error.self) {
            try DiskImageAllocator.allocate(at: path, logicalSize: 1024 * 1024)
        }
    }

    @Test func allocate_rejectsZeroSize() throws {
        let path = tmp.appendingPathComponent("zero.img")
        #expect(throws: DiskImageAllocator.Error.self) {
            try DiskImageAllocator.allocate(at: path, logicalSize: 0)
        }
    }
}
