import Foundation
import Testing
@testable import LuminaBootable

@Suite struct OmarchySeedTests {
    @Test func sha512CryptMatchesTheReferenceVector() {
        #expect(OmarchySeed.sha512Crypt("Hello world!", salt: "saltstring")
            == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }

    @Test func configurationSizesTheRootPartitionToTheDisk() throws {
        let config = OmarchySeed.configuration(hostname: "omarchy", diskBytes: 80 << 30)
        let disk = try #require((config["disk_config"] as? [String: Any])?["device_modifications"] as? [[String: Any]])
        let partitions = try #require(disk.first?["partitions"] as? [[String: Any]])
        let root = try #require((partitions[1]["size"] as? [String: Any])?["value"] as? UInt64)
        #expect(root == (80 << 30) - (2 << 30) - 2 * (1 << 20))
        #expect(config["hostname"] as? String == "omarchy")
    }
}
