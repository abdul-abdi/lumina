import CryptoKit
import Foundation
import Security

public enum OmarchySeed {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    public static func keychainService(for bundle: VMBundle) -> String {
        "lumina-\(bundle.manifest.name)"
    }

    public static func password(for bundle: VMBundle) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(for: bundle),
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(into bundle: VMBundle, user: String = NSUserName()) throws {
        let seed = bundle.seedDirectory
        let sshDir = bundle.rootURL.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)

        var bytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Error(description: "could not generate a password")
        }
        let password = Data(bytes).base64EncodedString()
        try storePassword(password, account: user, service: keychainService(for: bundle))
        var saltBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let hash = sha512Crypt(password, salt: String(saltBytes.map { cryptAlphabet[Int($0) % 64] }))

        let key = sshDir.appendingPathComponent("id_ed25519")
        try? FileManager.default.removeItem(at: key)
        try? FileManager.default.removeItem(at: key.appendingPathExtension("pub"))
        _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", keychainService(for: bundle), "-f", key.path])
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let files: [String: Any] = [
            "user_configuration.json": configuration(hostname: hostname(for: bundle), diskBytes: bundle.manifest.diskBytes),
            "user_credentials.json": [
                "root_enc_password": hash,
                "users": [["enc_password": hash, "groups": [], "sudo": true, "username": user]],
            ],
        ]
        for (name, object) in files {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: seed.appendingPathComponent(name))
        }
        try Data("false\n".utf8).write(to: seed.appendingPathComponent("user_encrypt_installation.txt"))
        try Data("\(publicKey)\n".utf8).write(to: seed.appendingPathComponent("authorized_keys"))
        try Data("instance-id: \(keychainService(for: bundle))\n".utf8).write(to: seed.appendingPathComponent("meta-data"))
        try Data("#cloud-config\nusers: []\ndisable_root: false\nssh_authorized_keys:\n  - \(publicKey)\n".utf8)
            .write(to: seed.appendingPathComponent("user-data"))
    }

    static func hostname(for bundle: VMBundle) -> String {
        let name = bundle.manifest.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let trimmed = String(name).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "omarchy" : String(trimmed.prefix(63))
    }

    static func configuration(hostname: String, diskBytes: UInt64) -> [String: Any] {
        let mib: UInt64 = 1 << 20
        let gib: UInt64 = 1 << 30
        func partition(start: UInt64, size: UInt64, fs: String, flags: [String], mount: String?, subvolumes: [[String: String]]) -> [String: Any] {
            func sectors(_ value: UInt64) -> [String: Any] {
                ["sector_size": ["unit": "B", "value": 512], "unit": "B", "value": value]
            }
            return [
                "btrfs": subvolumes, "dev_path": NSNull(), "flags": flags, "fs_type": fs,
                "mount_options": fs == "btrfs" ? ["compress=zstd"] : [],
                "mountpoint": mount.map { $0 as Any } ?? NSNull(),
                "obj_id": fs == "btrfs" ? "8c2c2b92-1070-455d-b76a-56263bab24aa" : "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                "size": sectors(size), "start": sectors(start), "status": "create", "type": "primary",
            ]
        }
        let mainStart = 2 * gib + mib
        let subvolumes = [
            ["mountpoint": "/", "name": "@"], ["mountpoint": "/home", "name": "@home"],
            ["mountpoint": "/var/log", "name": "@log"], ["mountpoint": "/var/cache/pacman/pkg", "name": "@pkg"],
        ]
        return [
            "archinstall-language": "English", "app_config": NSNull(), "auth_config": [String: Any](),
            "audio_config": ["audio": "pipewire"],
            "bootloader_config": ["bootloader": "Limine", "uki": false, "removable": false],
            "custom_commands": [String](),
            "omarchy_install": [
                "mode": "full_disk", "defer_provisioning": false, "target_mount": "/mnt",
                "boot": ["esp_mount": "/boot", "esp_path": "/EFI/limine", "efi_binary": "limine_aa64.efi", "enable_fallback": true],
                "storage": ["kernel": "linux-omarchy"],
            ],
            "disk_config": [
                "config_type": "default_layout",
                "device_modifications": [[
                    "device": "/dev/vda",
                    "partitions": [
                        partition(start: mib, size: 2 * gib, fs: "fat32", flags: ["boot", "esp"], mount: "/boot", subvolumes: []),
                        partition(start: mainStart, size: diskBytes - mainStart - mib, fs: "btrfs", flags: [], mount: nil, subvolumes: subvolumes),
                    ],
                    "wipe": true,
                ]],
            ],
            "hostname": hostname, "kernels": ["linux-omarchy"], "network_config": ["type": "iso"],
            "ntp": true, "parallel_downloads": 8, "script": NSNull(), "services": [String](), "swap": true, "timezone": "UTC",
            "locale_config": ["kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"],
            "mirror_config": [
                "custom_repositories": [String](), "custom_servers": [["url": "https://arm-mirror.omarchy.org/$arch/$repo"]],
                "mirror_regions": [String: Any](), "optional_repositories": [String](),
            ],
            "packages": ["base-devel", "git", "omarchy-keyring", "omarchy-settings-dev", "omarchy-dev"],
            "profile_config": ["gfx_driver": NSNull(), "greeter": NSNull(), "profile": [String: Any]()],
            "version": "3.0.9",
        ]
    }

    static let cryptAlphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func sha512Crypt(_ password: String, salt: String) -> String {
        let p = Array(password.utf8)
        let s = Array(salt.utf8.prefix(16))
        func hash(_ parts: [UInt8]...) -> [UInt8] {
            var h = SHA512()
            parts.forEach { h.update(data: $0) }
            return Array(h.finalize())
        }
        func stretch(_ digest: [UInt8], to length: Int) -> [UInt8] {
            (0..<length).map { digest[$0 % 64] }
        }
        let b = hash(p, s, p)
        var a = p + s + stretch(b, to: p.count)
        var bits = p.count
        while bits > 0 {
            a += bits & 1 == 1 ? b : p
            bits >>= 1
        }
        var c = hash(a)
        let pSeq = stretch(hash(Array(repeating: p, count: p.count).flatMap { $0 }), to: p.count)
        let sSeq = stretch(hash(Array(repeating: s, count: 16 + Int(c[0])).flatMap { $0 }), to: s.count)
        for i in 0..<5000 {
            var round = i % 2 == 1 ? pSeq : c
            if i % 3 != 0 { round += sSeq }
            if i % 7 != 0 { round += pSeq }
            round += i % 2 == 1 ? c : pSeq
            c = hash(round)
        }
        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var encoded = ""
        func emit(_ word: Int, _ count: Int) {
            var w = word
            for _ in 0..<count {
                encoded.append(cryptAlphabet[w & 0x3f])
                w >>= 6
            }
        }
        for (x, y, z) in order {
            emit(Int(c[x]) << 16 | Int(c[y]) << 8 | Int(c[z]), 4)
        }
        emit(Int(c[63]), 2)
        return "$6$\(String(decoding: s, as: UTF8.self))$\(encoded)"
    }

    private static func storePassword(_ password: String, account: String, service: String) throws {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(match as CFDictionary)
        var item = match
        item[kSecAttrAccount as String] = account
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error(description: "could not save the VM password to the Keychain (OSStatus \(status))")
        }
    }

    private static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data("\(input)\n".utf8)) }
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Error(description: "\(URL(fileURLWithPath: tool).lastPathComponent) exited \(process.terminationStatus)")
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
