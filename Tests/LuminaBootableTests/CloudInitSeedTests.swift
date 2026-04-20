// Tests/LuminaBootableTests/CloudInitSeedTests.swift
import Foundation
import Testing
@testable import LuminaBootable

@Suite struct CloudInitSeedTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaCloudInitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    @Test func defaultUserDataMentionsLuminaGuest() {
        #expect(CloudInitSeed.defaultUserData.contains("lumina-guest"))
        #expect(CloudInitSeed.defaultUserData.contains("guest.lumina.app"))
    }

    @Test func defaultUserDataIsCloudConfigShape() {
        #expect(CloudInitSeed.defaultUserData.hasPrefix("#cloud-config"))
    }

    @Test func defaultMetaDataHasInstanceID() {
        #expect(CloudInitSeed.defaultMetaData.contains("instance-id"))
    }

    @Test func generate_producesISOAtExpectedPath() throws {
        let seed = CloudInitSeed(bundleRootURL: tmp)
        let outURL = try seed.generate()
        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(outURL.lastPathComponent == "cidata.iso")
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        #expect(size > 0)
    }
}
