// Tests/LuminaTests/EFIBootableTests.swift
import Foundation
import Testing
import Virtualization
@testable import Lumina
@testable import LuminaBootable

@Suite struct EFIBootableTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuminaEFIBootableTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    /// Minimal VZVirtualMachineConfiguration that EFIBootable can plug into.
    /// CPU + memory must be set before `EFIBootable.apply(to:)` runs because
    /// `VZEFIVariableStore.init(creatingVariableStoreAt:)` has no dependency
    /// on those, but validation later does.
    private func baseConfig() -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2
        config.memorySize = 2 * 1024 * 1024 * 1024
        return config
    }

    @Test func configure_setsEFIBootLoaderWithVariableStore() throws {
        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)

        let cfg = EFIBootConfig(variableStoreURL: vars, primaryDisk: disk)
        let vzConfig = baseConfig()

        try EFIBootable(config: cfg).apply(to: vzConfig)

        #expect(vzConfig.bootLoader is VZEFIBootLoader)
        let loader = vzConfig.bootLoader as! VZEFIBootLoader
        #expect(loader.variableStore?.url.lastPathComponent == "efi.vars")

        // Primary disk became the first storage device.
        #expect(vzConfig.storageDevices.count >= 1)
        #expect(vzConfig.storageDevices[0] is VZVirtioBlockDeviceConfiguration)
    }

    @Test func configure_createsVariableStoreIfMissing() throws {
        let vars = tmp.appendingPathComponent("new.vars")
        let disk = tmp.appendingPathComponent("d.img")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)
        #expect(!FileManager.default.fileExists(atPath: vars.path))

        let cfg = EFIBootConfig(variableStoreURL: vars, primaryDisk: disk)
        try EFIBootable(config: cfg).apply(to: baseConfig())

        #expect(FileManager.default.fileExists(atPath: vars.path))
    }

    @Test func configure_reusesExistingVariableStore() async throws {
        let vars = tmp.appendingPathComponent("existing.vars")
        let disk = tmp.appendingPathComponent("d.img")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)

        // First call creates.
        let cfg = EFIBootConfig(variableStoreURL: vars, primaryDisk: disk)
        try EFIBootable(config: cfg).apply(to: baseConfig())
        #expect(FileManager.default.fileExists(atPath: vars.path))

        // Second call should reuse — the file on disk must be preserved.
        // Capture mtime, sleep 20ms, apply again, verify mtime unchanged.
        let beforeModDate = (try FileManager.default.attributesOfItem(atPath: vars.path)[.modificationDate] as? Date)
        try await Task.sleep(for: .milliseconds(20))
        try EFIBootable(config: cfg).apply(to: baseConfig())
        let afterModDate = (try FileManager.default.attributesOfItem(atPath: vars.path)[.modificationDate] as? Date)
        #expect(beforeModDate == afterModDate, "variable store file should not be rewritten on reuse")
    }

    @Test func configure_attachesCdromWhenPresent() throws {
        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        let iso = tmp.appendingPathComponent("tiny.iso")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)
        // Zero-filled stub ISO — VZDiskImageStorageDeviceAttachment accepts
        // any regular file; boot would fail but the config-shape test here
        // only cares that the device is attached.
        FileManager.default.createFile(atPath: iso.path, contents: Data(count: 64 * 1024))

        let cfg = EFIBootConfig(variableStoreURL: vars, primaryDisk: disk, cdromISO: iso)
        let vzConfig = baseConfig()

        try EFIBootable(config: cfg).apply(to: vzConfig)

        // CD-ROM is appended as a read-only virtio block device so macOS 14
        // hosts don't need VZUSBMassStorageDeviceConfiguration (macOS 15+).
        // Primary disk + CD-ROM = 2 storage devices.
        #expect(vzConfig.storageDevices.count == 2)
        // The second device's attachment is marked read-only.
        let cdromDevice = vzConfig.storageDevices[1] as? VZVirtioBlockDeviceConfiguration
        #expect(cdromDevice != nil)
    }

    @Test func configure_usesVirtioBlockCDROMByDefault() throws {
        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        let iso = tmp.appendingPathComponent("linux.iso")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)
        FileManager.default.createFile(atPath: iso.path, contents: Data(count: 64 * 1024))

        // preferUSBCDROM defaults to false — virtio block for Linux.
        let cfg = EFIBootConfig(variableStoreURL: vars, primaryDisk: disk, cdromISO: iso)
        let vzConfig = baseConfig()
        try EFIBootable(config: cfg).apply(to: vzConfig)

        let cdrom = vzConfig.storageDevices[1]
        #expect(cdrom is VZVirtioBlockDeviceConfiguration)
    }

    @Test func configure_usesUSBMassStorageCDROMWhenPreferred() throws {
        // macOS 13+ only — older hosts always get virtio block and this
        // test degrades gracefully to pass-through.
        guard #available(macOS 13.0, *) else { return }

        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        let iso = tmp.appendingPathComponent("windows.iso")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)
        FileManager.default.createFile(atPath: iso.path, contents: Data(count: 64 * 1024))

        let cfg = EFIBootConfig(
            variableStoreURL: vars,
            primaryDisk: disk,
            cdromISO: iso,
            preferUSBCDROM: true
        )
        let vzConfig = baseConfig()
        try EFIBootable(config: cfg).apply(to: vzConfig)

        let cdrom = vzConfig.storageDevices[1]
        #expect(cdrom is VZUSBMassStorageDeviceConfiguration,
                "Windows-family bundles should get USB mass-storage for the installer ISO")
    }

    @Test func configure_installPhaseFlagPropagates() throws {
        // Smoke-test that installPhase flag roundtrips through apply()
        // without crashing. The actual `VZDiskImageSynchronizationMode`
        // selection is internal — we trust the unit-test surface for the
        // flag and exercise end-to-end in an install benchmark.
        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)

        let installCfg = EFIBootConfig(
            variableStoreURL: vars,
            primaryDisk: disk,
            installPhase: true
        )
        try EFIBootable(config: installCfg).apply(to: baseConfig())

        let normalCfg = EFIBootConfig(
            variableStoreURL: vars,
            primaryDisk: disk,
            installPhase: false
        )
        try EFIBootable(config: normalCfg).apply(to: baseConfig())
    }

    @Test func configure_attachesExtraDisks() throws {
        let vars = tmp.appendingPathComponent("efi.vars")
        let disk = tmp.appendingPathComponent("disk.img")
        let extra1 = tmp.appendingPathComponent("data1.img")
        let extra2 = tmp.appendingPathComponent("data2.img")
        try DiskImageAllocator.allocate(at: disk, logicalSize: 64 * 1024 * 1024)
        try DiskImageAllocator.allocate(at: extra1, logicalSize: 64 * 1024 * 1024)
        try DiskImageAllocator.allocate(at: extra2, logicalSize: 64 * 1024 * 1024)

        let cfg = EFIBootConfig(
            variableStoreURL: vars,
            primaryDisk: disk,
            extraDisks: [extra1, extra2]
        )
        let vzConfig = baseConfig()

        try EFIBootable(config: cfg).apply(to: vzConfig)

        // 1 primary + 2 extras = 3 storage devices.
        #expect(vzConfig.storageDevices.count == 3)
    }
}
