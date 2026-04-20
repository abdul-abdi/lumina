// Sources/LuminaBootable/CloudInitSeed.swift
//
// v0.7.0 M7 — generates a NoCloud cloud-init seed ISO that auto-installs
// the `lumina-guest` package on first boot of a Linux desktop guest.
//
// Layout of a NoCloud ISO (volume label MUST be `cidata`):
//   /meta-data
//   /user-data
//   /vendor-data    (optional, omitted)
//
// The ISO is mounted as a second virtual CD-ROM (separate from the
// installer ISO). cloud-init in the live installer environment reads it
// during install and persists the package install into the target system.

import Foundation

public struct CloudInitSeed: Sendable {
    public let bundleRootURL: URL
    public let metaData: String
    public let userData: String

    public init(
        bundleRootURL: URL,
        metaData: String = CloudInitSeed.defaultMetaData,
        userData: String = CloudInitSeed.defaultUserData
    ) {
        self.bundleRootURL = bundleRootURL
        self.metaData = metaData
        self.userData = userData
    }

    public static let defaultMetaData = """
    instance-id: lumina-vm
    local-hostname: lumina-vm
    """

    /// Default cloud-init user-data: installs lumina-guest from our repo,
    /// enables it as a systemd service, creates a default user with sudo.
    public static let defaultUserData = """
    #cloud-config
    ssh_pwauth: false
    package_update: true
    packages:
      - curl
      - ca-certificates
    runcmd:
      - [ sh, -c, "curl -fsSL https://guest.lumina.app/install.sh | sh" ]
      - [ systemctl, enable, --now, lumina-guest.service ]
    users:
      - name: lumina
        gecos: Lumina default user
        groups: sudo
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        lock_passwd: false
        plain_text_passwd: lumina
    """

    public enum Error: Swift.Error, Equatable {
        case writeFailed(URL, String)
        case mkisofsNotAvailable
        case mkisofsFailed(Int32, String)
    }

    /// Generate a `.iso` file containing the seed under
    /// `<bundle>/cidata.iso`. Uses `hdiutil` (macOS native) to build the
    /// ISO. Returns the URL of the generated seed.
    public func generate() throws -> URL {
        let outURL = bundleRootURL.appendingPathComponent("cidata.iso")
        let staging = bundleRootURL.appendingPathComponent("cidata-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data(metaData.utf8).write(to: staging.appendingPathComponent("meta-data"))
            try Data(userData.utf8).write(to: staging.appendingPathComponent("user-data"))
        } catch {
            throw Error.writeFailed(staging, "\(error)")
        }

        // hdiutil produces a UDF/ISO image. NoCloud needs the volume name
        // 'cidata' so cloud-init's NoCloud datasource finds it.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name", "cidata",
            "-o", outURL.path,
            staging.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Error.mkisofsFailed(-1, "\(error)")
        }
        if proc.terminationStatus != 0 {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Error.mkisofsFailed(proc.terminationStatus, stderr)
        }

        return outURL
    }
}
