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

    @Test func defaultUserDataHasNoLoginAccount() {
        // No `users:` block, no `plain_text_passwd`, no `lock_passwd: false` —
        // the default seed must not ship a known-credential login path.
        #expect(!CloudInitSeed.defaultUserData.contains("plain_text_passwd"))
        #expect(!CloudInitSeed.defaultUserData.contains("lock_passwd: false"))
        #expect(CloudInitSeed.defaultUserData.contains("ssh_pwauth: false"))
        #expect(CloudInitSeed.defaultUserData.contains("disable_root: true"))
    }

    @Test func userDataWithAuthorizedKey_locksPasswordAndEmbedsKey() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1l test@example"
        let body = try CloudInitSeed.userData(authorizedKeys: [key])
        #expect(body.contains("lock_passwd: true"))
        #expect(body.contains("ssh_pwauth: false"))
        #expect(body.contains(key))
        #expect(!body.contains("plain_text_passwd"))
    }

    @Test func userData_rejectsEmptyKeyList() {
        #expect(throws: CloudInitSeed.Error.missingAuthorizedKey) {
            _ = try CloudInitSeed.userData(authorizedKeys: [])
        }
        #expect(throws: CloudInitSeed.Error.missingAuthorizedKey) {
            _ = try CloudInitSeed.userData(authorizedKeys: ["   "])
        }
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
