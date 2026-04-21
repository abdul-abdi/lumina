// Sources/LuminaBootable/ISOInspector.swift
//
// v0.7.0 M4 — pre-flight check that an installer ISO is ARM64.
//
// Lumina only boots aarch64 guests (VZ framework limitation; we don't
// emulate x86). Catching this at `lumina desktop create` time is much
// friendlier than letting EFI sit at a black screen for 30 seconds and
// then time out.
//
// Detection strategy: read the ISO root directory and look for the
// canonical EFI bootloader filenames Microsoft / GRUB / shim use.
//   - BOOTAA64.EFI / bootaa64.efi → ARM64
//   - BOOTX64.EFI  / bootx64.efi  → x86_64
//   - BOOTRISCV64.EFI             → riscv64 (informational; we still reject)
// If none are present, return .unknown — the user can still proceed but
// we surface a warning.
//
// Approach: open the file, read first 1 MB, byte-search for these strings.
// ISO9660 is structured but we don't need to decode it — the EFI
// bootloader filenames are present in directory records as plain ASCII.

import Foundation

public struct ISOInspector: Sendable {
    public enum Architecture: Sendable, Equatable {
        case arm64
        case x86_64
        case riscv64
        case unknown
    }

    public enum Error: Swift.Error, Equatable {
        case fileNotFound(URL)
        case readFailed(URL)
    }

    /// Inspect the first 1 MB of the file for EFI bootloader filenames.
    /// 1 MB easily covers the ISO9660 path table on small images.
    public static func detectArchitecture(at url: URL) throws -> Architecture {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound(url)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Error.readFailed(url)
        }
        defer { try? handle.close() }

        let chunk = handle.readData(ofLength: 1024 * 1024)
        let upper = chunk.uppercaseASCII()

        if upper.range(of: Data("BOOTAA64.EFI".utf8)) != nil { return .arm64 }
        if upper.range(of: Data("BOOTX64.EFI".utf8)) != nil { return .x86_64 }
        if upper.range(of: Data("BOOTRISCV64.EFI".utf8)) != nil { return .riscv64 }

        // Fallback: some distros (Debian) put the EFI binary deeper in the
        // path table beyond 1 MB. Read another 4 MB if the file is big enough.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        if size > 1024 * 1024 {
            handle.seek(toFileOffset: 1024 * 1024)
            let extra = handle.readData(ofLength: 4 * 1024 * 1024).uppercaseASCII()
            if extra.range(of: Data("BOOTAA64.EFI".utf8)) != nil { return .arm64 }
            if extra.range(of: Data("BOOTX64.EFI".utf8)) != nil { return .x86_64 }
        }

        return .unknown
    }
}

private extension Data {
    /// In-place uppercase A-Z conversion of ASCII bytes; non-ASCII bytes
    /// (>= 0x80) are left alone. Cheaper than String round-tripping.
    func uppercaseASCII() -> Data {
        var out = self
        for i in 0..<out.count {
            let b = out[i]
            if b >= 0x61 && b <= 0x7A {  // 'a'-'z'
                out[i] = b - 0x20
            }
        }
        return out
    }
}
