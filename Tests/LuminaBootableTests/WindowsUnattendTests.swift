// Tests/LuminaBootableTests/WindowsUnattendTests.swift
//
// Tests for the Windows 11 ARM auto-bypass sidecar.
// Covers XML correctness (LabConfig keys, pass=windowsPE) and ISO
// generation (file lands at expected path, contains autounattend.xml
// at root). Real Win11 install verification is deferred to manual
// smoke once a Windows ARM ISO is on hand.

import Foundation
import Testing
@testable import LuminaBootable

@Suite struct WindowsUnattendTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowsUnattendTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    // MARK: - XML

    @Test func defaultsBypassEverything() {
        let u = WindowsUnattend.allBypasses
        #expect(u.bypassTPMCheck)
        #expect(u.bypassSecureBootCheck)
        #expect(u.bypassRAMCheck)
        #expect(u.bypassCPUCheck)
        #expect(u.bypassStorageCheck)
    }

    @Test func generatedXMLContainsAllFiveBypassKeys() {
        let xml = WindowsUnattend.allBypasses.generateXML()
        #expect(xml.contains("BypassTPMCheck"))
        #expect(xml.contains("BypassSecureBootCheck"))
        #expect(xml.contains("BypassRAMCheck"))
        #expect(xml.contains("BypassCPUCheck"))
        #expect(xml.contains("BypassStorageCheck"))
    }

    @Test func generatedXMLTargetsWindowsPEPass() {
        let xml = WindowsUnattend.allBypasses.generateXML()
        // The readiness check fires in windowsPE — bypass keys MUST
        // land in that pass, not specialize/oobeSystem/etc.
        #expect(xml.contains(#"<settings pass="windowsPE">"#))
    }

    @Test func generatedXMLDeclaresArm64Architecture() {
        let xml = WindowsUnattend.allBypasses.generateXML()
        #expect(xml.contains(#"processorArchitecture="arm64""#))
    }

    @Test func generatedXMLOmitsDisabledBypasses() {
        var u = WindowsUnattend()
        u.bypassTPMCheck = true
        u.bypassSecureBootCheck = false
        u.bypassRAMCheck = false
        u.bypassCPUCheck = false
        u.bypassStorageCheck = false
        let xml = u.generateXML()
        #expect(xml.contains("BypassTPMCheck"))
        #expect(!xml.contains("BypassSecureBootCheck"))
        #expect(!xml.contains("BypassRAMCheck"))
        #expect(!xml.contains("BypassCPUCheck"))
        #expect(!xml.contains("BypassStorageCheck"))
    }

    @Test func generatedXMLIsValidPlistOrXML() throws {
        let xml = WindowsUnattend.allBypasses.generateXML()
        // Sanity: parseable as XML by Foundation. Doesn't validate
        // the unattend schema — that requires the Microsoft XSDs —
        // but it catches gross malformation (missing closing tags,
        // bad escaping, etc.).
        let data = Data(xml.utf8)
        let parser = XMLParser(data: data)
        let delegate = ValidationDelegate()
        parser.delegate = delegate
        #expect(parser.parse(), "XML should parse cleanly")
        #expect(!delegate.sawError, "no XMLParser error events")
    }

    @Test func generatedXMLOrdersCommandsSequentially() {
        let xml = WindowsUnattend.allBypasses.generateXML()
        // Commands must have <Order>1</Order>, <Order>2</Order>, …
        // contiguous from 1 — Microsoft's runner skips
        // out-of-sequence orders silently.
        for n in 1...5 {
            #expect(xml.contains("<Order>\(n)</Order>"), "missing Order \(n)")
        }
    }

    @Test func generatedXMLUsesSingleBackslashRegistryPaths() {
        // Regression: a raw-string typo in v1 produced
        // `HKLM\\System\\Setup\\LabConfig` with literal double
        // backslashes, which reg.exe rejects with "registry path
        // not found". Real Windows paths use single backslashes per
        // component. This test guards against the typo.
        let xml = WindowsUnattend.allBypasses.generateXML()
        #expect(xml.contains(#"HKLM\System\Setup\LabConfig"#))
        #expect(!xml.contains(#"HKLM\\System"#),
                "registry path must not have doubled backslashes")
    }

    // MARK: - ISO

    @Test func generateISO_writesToExpectedPath() throws {
        let outURL = try WindowsUnattend.allBypasses.generateISO(in: tmp)
        #expect(outURL.lastPathComponent == "win-unattend.iso")
        #expect(FileManager.default.fileExists(atPath: outURL.path))

        // Reasonable size — autounattend.xml + ISO9660 + Joliet
        // overhead. Empirically observed at ~900 KB for the
        // all-bypasses payload (hdiutil's makehybrid pads
        // aggressively for Joliet directory structures even with a
        // single file). Assert >2 KB to catch empty images and <4 MB
        // to catch genuinely runaway pad.
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        #expect(size > 2_000, "ISO suspiciously small (\(size) bytes)")
        #expect(size < 4 * 1024 * 1024, "ISO suspiciously large (\(size) bytes)")
    }

    @Test func generateISO_containsAutounattendAtRoot() throws {
        let outURL = try WindowsUnattend.allBypasses.generateISO(in: tmp)
        // Use bsdtar to list the ISO's contents and verify
        // autounattend.xml lives at the root (no subdirectory).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        proc.arguments = ["-tf", outURL.path]
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let listing = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        proc.waitUntilExit()

        let entries = listing.split(separator: "\n").map(String.init)
        let hasUnattendAtRoot = entries.contains(where: { entry in
            // Accept "autounattend.xml" or "./autounattend.xml" with
            // any case; reject any path containing a slash before
            // the filename (i.e., subdirectory entries).
            let normalized = entry
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            return normalized == "autounattend.xml"
        })
        #expect(hasUnattendAtRoot, "autounattend.xml not found at root; entries=\(entries)")
    }

    @Test func generateISO_isIdempotentAcrossRuns() throws {
        let first = try WindowsUnattend.allBypasses.generateISO(in: tmp)
        let firstSize = (try FileManager.default
            .attributesOfItem(atPath: first.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        let second = try WindowsUnattend.allBypasses.generateISO(in: tmp)
        let secondSize = (try FileManager.default
            .attributesOfItem(atPath: second.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        #expect(first.path == second.path, "should overwrite, not append")
        #expect(firstSize == secondSize, "deterministic content")
    }
}

private final class ValidationDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    var sawError = false
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        sawError = true
    }
}
