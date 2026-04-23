// Tests/LuminaTests/TypesTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func runOptionsDefaults() {
    let opts = RunOptions.default
    #expect(opts.timeout == .seconds(60))
    #expect(opts.memory == 1024 * 1024 * 1024)
    #expect(opts.cpuCount == 2)
    #expect(opts.image == "default")
    #expect(opts.directoryUploads.isEmpty)
    #expect(opts.directoryDownloads.isEmpty)
}

@Test func directoryUploadInit() {
    let upload = DirectoryUpload(localPath: URL(fileURLWithPath: "/tmp/mydir"), remotePath: "/data")
    #expect(upload.localPath.path == "/tmp/mydir")
    #expect(upload.remotePath == "/data")
}

@Test func directoryDownloadInit() {
    let download = DirectoryDownload(remotePath: "/app/dist", localPath: URL(fileURLWithPath: "/tmp/output"))
    #expect(download.remotePath == "/app/dist")
    #expect(download.localPath.path == "/tmp/output")
}

@Test func vmOptionsFromRunOptions() {
    let run = RunOptions(timeout: .seconds(30), memory: 1024 * 1024 * 1024, cpuCount: 4, image: "custom")
    let vm = VMOptions(from: run)
    #expect(vm.memory == 1024 * 1024 * 1024)
    #expect(vm.cpuCount == 4)
    #expect(vm.image == "custom")
}

@Test func runResultSuccess() {
    let success = RunResult(stdout: "ok", stderr: "", exitCode: 0, wallTime: .seconds(1))
    #expect(success.success == true)

    let failure = RunResult(stdout: "", stderr: "err", exitCode: 1, wallTime: .seconds(1))
    #expect(failure.success == false)
}

@Test func outputChunkEquality() {
    #expect(OutputChunk.stdout("hello") == OutputChunk.stdout("hello"))
    #expect(OutputChunk.stdout("hello") != OutputChunk.stderr("hello"))
    #expect(OutputChunk.exit(0) == OutputChunk.exit(0))
    #expect(OutputChunk.exit(0) != OutputChunk.exit(1))
}

@Test func connectionStateEquality() {
    #expect(ConnectionState.disconnected == ConnectionState.disconnected)
    #expect(ConnectionState.ready != ConnectionState.failed)
    #expect(ConnectionState.connecting != ConnectionState.waitingForReady)
    #expect(ConnectionState.failed != ConnectionState.ready)
    #expect(ConnectionState.failed != ConnectionState.disconnected)
    #expect(ConnectionState.failed == ConnectionState.failed)
}

@Test func guestMessageHeartbeatEquality() {
    #expect(GuestMessage.heartbeat == GuestMessage.heartbeat)
    #expect(GuestMessage.heartbeat != GuestMessage.ready)
}

@Test func runOptionsWorkingDirectoryDefaultNil() {
    let opts = RunOptions()
    #expect(opts.workingDirectory == nil)
}

@Test func vmOptionsRosettaDefaultFalse() {
    let opts = VMOptions()
    #expect(opts.rosetta == false)
}

@Test func runOptionsNoRosettaField() {
    // rosetta moved to image metadata — RunOptions no longer has it
    let opts = RunOptions()
    #expect(opts.image == "default")
    #expect(opts.diskSize == nil)
    // Verify no directoryUploads/Downloads by default
    #expect(opts.directoryUploads.isEmpty)
    #expect(opts.directoryDownloads.isEmpty)
}

@Test func luminaErrorDescriptions() {
    #expect(LuminaError.imageNotFound("myimg").errorDescription == "image 'myimg' not found")
    #expect(LuminaError.sessionNotFound("abc-123").errorDescription == "session 'abc-123' not found")
    #expect(LuminaError.sessionDead("abc-123").errorDescription == "session 'abc-123' is no longer running")
    #expect(LuminaError.sessionFailed("disk full").errorDescription == "session failed: disk full")
    #expect(LuminaError.connectionFailed.errorDescription == "failed to connect to guest agent")
    #expect(LuminaError.timeout.errorDescription == "command timed out")
    #expect(LuminaError.protocolError("bad json").errorDescription == "protocol error: bad json")
    #expect(LuminaError.uploadFailed(path: "/tmp/x", reason: "disk full").errorDescription == "upload failed for '/tmp/x': disk full")
    #expect(LuminaError.downloadFailed(path: "/tmp/y", reason: "file not found").errorDescription == "download failed for '/tmp/y': file not found")
}


// MARK: - v0.7.0 M3 — BootableProfile types

@Test func agentImageRef_initWithImageName_storesName() {
    let ref = AgentImageRef(image: "default")
    #expect(ref.image == "default")
}

@Test func agentImageRef_initWithCustomName_storesName() {
    let ref = AgentImageRef(image: "my-image")
    #expect(ref.image == "my-image")
}

@Test func agentImageRef_isSendable() {
    func takeSendable<T: Sendable>(_: T) {}
    takeSendable(AgentImageRef(image: "x"))
}

@Test func efiBootConfig_allFieldsRoundTrip() {
    let tmp = FileManager.default.temporaryDirectory
    let cfg = EFIBootConfig(
        variableStoreURL: tmp.appendingPathComponent("efi.vars"),
        primaryDisk: tmp.appendingPathComponent("disk.img"),
        cdromISO: tmp.appendingPathComponent("cd.iso"),
        extraDisks: [tmp.appendingPathComponent("data.img")]
    )
    #expect(cfg.variableStoreURL.lastPathComponent == "efi.vars")
    #expect(cfg.primaryDisk.lastPathComponent == "disk.img")
    #expect(cfg.cdromISO?.lastPathComponent == "cd.iso")
    #expect(cfg.extraDisks.count == 1)
}

@Test func efiBootConfig_optionalCdromNil() {
    let tmp = FileManager.default.temporaryDirectory
    let cfg = EFIBootConfig(
        variableStoreURL: tmp.appendingPathComponent("v"),
        primaryDisk: tmp.appendingPathComponent("d")
    )
    #expect(cfg.cdromISO == nil)
    #expect(cfg.extraDisks.isEmpty)
}

@Test func macOSBootConfig_storesPaths() {
    let tmp = FileManager.default.temporaryDirectory
    let cfg = MacOSBootConfig(
        ipsw: tmp.appendingPathComponent("UniversalMac.ipsw"),
        auxiliaryStorage: tmp.appendingPathComponent("aux.img"),
        primaryDisk: tmp.appendingPathComponent("disk.img")
    )
    #expect(cfg.ipsw.lastPathComponent == "UniversalMac.ipsw")
    #expect(cfg.auxiliaryStorage.lastPathComponent == "aux.img")
    #expect(cfg.primaryDisk.lastPathComponent == "disk.img")
    #expect(cfg.hardwareModel == nil)
    #expect(cfg.machineIdentifier == nil)
}

@Test func bootableProfile_agentCase() {
    let p = BootableProfile.agent(AgentImageRef(image: "default"))
    if case .agent(let ref) = p {
        #expect(ref.image == "default")
    } else {
        Issue.record("expected .agent case")
    }
}

@Test func bootableProfile_efiCase() {
    let tmp = FileManager.default.temporaryDirectory
    let p = BootableProfile.efi(EFIBootConfig(
        variableStoreURL: tmp.appendingPathComponent("v"),
        primaryDisk: tmp.appendingPathComponent("d")
    ))
    if case .efi = p {} else { Issue.record("expected .efi case") }
}

@Test func bootableProfile_macOSCase() {
    let tmp = FileManager.default.temporaryDirectory
    let p = BootableProfile.macOS(MacOSBootConfig(
        ipsw: tmp.appendingPathComponent("i"),
        auxiliaryStorage: tmp.appendingPathComponent("a"),
        primaryDisk: tmp.appendingPathComponent("d")
    ))
    if case .macOS = p {} else { Issue.record("expected .macOS case") }
}

@Test func vmOptions_defaultBootableIsNil() {
    let opts = VMOptions.default
    #expect(opts.bootable == nil)
}

@Test func vmOptions_effectiveBootable_derivesAgentFromImage() {
    var opts = VMOptions.default
    opts.image = "my-custom"
    let effective = opts.effectiveBootable
    if case .agent(let ref) = effective {
        #expect(ref.image == "my-custom")
    } else {
        Issue.record("expected derived .agent profile")
    }
}

// MARK: - v0.7.0 M4 — SoundConfig

@Test func soundConfig_defaultStreamCount() {
    let s = SoundConfig(enabled: true)
    #expect(s.enabled)
    #expect(s.streamCount == 1)
}

@Test func soundConfig_disabledIsValid() {
    let s = SoundConfig(enabled: false)
    #expect(!s.enabled)
}

@Test func soundConfig_explicitStreamCount() {
    let s = SoundConfig(enabled: true, streamCount: 2)
    #expect(s.streamCount == 2)
}

@Test func vmOptions_defaultSoundIsNil() {
    let o = VMOptions.default
    #expect(o.sound == nil)
}

@Test func vmOptions_canSetSound() {
    var o = VMOptions.default
    o.sound = SoundConfig(enabled: true)
    #expect(o.sound?.enabled == true)
}

@Test func vmOptions_effectiveBootable_preservesExplicitEFI() {
    let tmp = FileManager.default.temporaryDirectory
    var opts = VMOptions.default
    opts.bootable = .efi(EFIBootConfig(
        variableStoreURL: tmp.appendingPathComponent("v"),
        primaryDisk: tmp.appendingPathComponent("d")
    ))
    if case .efi = opts.effectiveBootable {} else {
        Issue.record("explicit .efi should survive")
    }
}

@Test func vmOptionsAutoDetectsRosettaFromImageMeta() throws {
    // Create a temp image with rosetta metadata
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumina-types-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("rosetta-img"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let meta = ImageMeta(base: nil, command: nil, created: Date(), rosetta: true)
    try JSONEncoder().encode(meta).write(to: tmpDir.appendingPathComponent("rosetta-img/meta.json"))
    try Data("k".utf8).write(to: tmpDir.appendingPathComponent("rosetta-img/vmlinuz"))
    try Data("r".utf8).write(to: tmpDir.appendingPathComponent("rosetta-img/rootfs.img"))

    // VMOptions.init(from:) reads ImageStore().readMeta — but uses default baseDir
    // So test the readMeta path directly
    let store = ImageStore(baseDir: tmpDir)
    let readMeta = store.readMeta(name: "rosetta-img")
    #expect(readMeta?.rosetta == true)

    // And verify no-meta image returns false
    try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("plain-img"), withIntermediateDirectories: true)
    try Data("k".utf8).write(to: tmpDir.appendingPathComponent("plain-img/vmlinuz"))
    try Data("r".utf8).write(to: tmpDir.appendingPathComponent("plain-img/rootfs.img"))
    let plainMeta = store.readMeta(name: "plain-img")
    #expect(plainMeta == nil) // no meta.json → nil
}

// MARK: - LuminaError.isCancellation

@Test func luminaError_isCancellation_detectsVMErrorCancelled() {
    let err = LuminaError.bootFailed(underlying: VMError.cancelled)
    #expect(err.isCancellation)
}

@Test func luminaError_isCancellation_falseForOtherVMErrors() {
    #expect(!LuminaError.bootFailed(underlying: VMError.pipeFailed).isCancellation)
    #expect(!LuminaError.bootFailed(underlying: VMError.noSocketDevice).isCancellation)
    #expect(!LuminaError.bootFailed(underlying: VMError.invalidState("x")).isCancellation)
}

@Test func luminaError_isCancellation_falseForNonBootFailed() {
    #expect(!LuminaError.connectionFailed.isCancellation)
    #expect(!LuminaError.timeout.isCancellation)
    #expect(!LuminaError.guestCrashed(serialOutput: "panic").isCancellation)
    #expect(!LuminaError.imageNotFound("x").isCancellation)
}

// MARK: - BootPhases

@Test func bootPhases_defaultsToZero() {
    let p = BootPhases()
    #expect(p.configMs == 0)
    #expect(p.vzStartMs == 0)
    #expect(p.totalMs == 0)
}

@Test func bootPhases_isEquatable() {
    var a = BootPhases()
    var b = BootPhases()
    #expect(a == b)
    a.vzStartMs = 42
    #expect(a != b)
    b.vzStartMs = 42
    #expect(a == b)
}

@Test func bootPhases_isValid_reflectsAnyObservedPhase() {
    // Attached-only VM / unobserved boot: every field zero, isValid false.
    var p = BootPhases()
    #expect(!p.isValid)

    // Partial observation (cancelled mid-boot before totalMs is written):
    // isValid flips true as soon as any phase has been recorded. This
    // matches the docstring contract — "any phase observed" — and lets
    // UI show partial timings for a boot that crashed mid-sequence.
    p.configMs = 5
    #expect(p.isValid)

    // Completed boot (VM.boot ran to `.ready`): still valid.
    p = BootPhases()
    p.totalMs = 390
    #expect(p.isValid)

    // Any one non-zero phase is sufficient — spot-check a few that
    // cover different boot paths (agent vs EFI vs mid-network config).
    for kp: WritableKeyPath<BootPhases, Double> in [
        \.imageResolveMs, \.cloneMs, \.vzStartMs, \.vsockConnectMs,
        \.runnerReadyMs, \.networkConfigMs,
    ] {
        var q = BootPhases()
        q[keyPath: kp] = 1
        #expect(q.isValid)
    }
}
