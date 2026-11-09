import Foundation
import Security

public enum UbuntuAutoinstall {
    public static func write(into seed: URL, user: String = "lumina", password: String = "lumina") throws {
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        var saltBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let hash = OmarchySeed.sha512Crypt(password, salt: String(saltBytes.map { OmarchySeed.cryptAlphabet[Int($0) % 64] }))
        let userData = """
        #cloud-config
        autoinstall:
          version: 1
          locale: en_US.UTF-8
          keyboard:
            layout: us
          identity:
            hostname: lumina-vm
            username: \(user)
            password: "\(hash)"
          ssh:
            install-server: true
            allow-pw: true
          storage:
            layout:
              name: direct
          packages:
            - ubuntu-desktop-minimal
          shutdown: poweroff

        """
        try Data(userData.utf8).write(to: seed.appendingPathComponent("user-data"))
        try Data("instance-id: lumina-ubuntu\n".utf8).write(to: seed.appendingPathComponent("meta-data"))
    }
}
