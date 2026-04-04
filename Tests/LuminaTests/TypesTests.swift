// Tests/LuminaTests/TypesTests.swift
import Testing
@testable import Lumina

@Test func runOptionsDefaults() {
    let opts = RunOptions.default
    #expect(opts.timeout == .seconds(60))
    #expect(opts.memory == 512 * 1024 * 1024)
    #expect(opts.cpuCount == 2)
    #expect(opts.image == "default")
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
