// Tests/LuminaTests/SerialConsoleTests.swift
import Foundation
import Testing
@testable import Lumina

@Test func serialConsoleCaptures() async {
    let console = SerialConsole()
    console.append(Data("boot message\n".utf8))
    console.append(Data("lumina-agent starting\n".utf8))

    let output = console.output
    #expect(output.contains("boot message"))
    #expect(output.contains("lumina-agent starting"))
}

@Test func serialConsoleKeepsTail() async {
    let console = SerialConsole(maxSize: 32)
    // Write more than maxSize to verify tail is kept
    console.append(Data("AAAAAAAAAAAAAAAA".utf8)) // 16 bytes
    console.append(Data("BBBBBBBBBBBBBBBB".utf8)) // 16 bytes — now at 32
    console.append(Data("CCCCCCCCCCCCCCCC".utf8)) // 16 more — should evict A's

    let output = console.output
    #expect(!output.contains("AAAA"))
    #expect(output.contains("CCCC"))
}

@Test func serialConsoleDetectsAgentReady() async {
    let console = SerialConsole()
    #expect(!console.agentStarted)
    console.append(Data("kernel booting...\n".utf8))
    #expect(!console.agentStarted)
    console.append(Data("lumina-agent starting\n".utf8))
    #expect(console.agentStarted)
}

@Test func serialConsoleVersionMonotonic() async {
    let console = SerialConsole()
    // Fresh console: version starts at 0.
    #expect(console.version == 0)

    console.append(Data("line 1\n".utf8))
    let v1 = console.version
    #expect(v1 == 1)

    console.append(Data("line 2\n".utf8))
    let v2 = console.version
    #expect(v2 > v1)

    // Empty appends must not bump the version — back-pressure
    // contract: readers rely on `version` changing iff new bytes
    // actually landed in the buffer. An empty append is a no-op,
    // and a reader who polls between two no-ops should skip its
    // whole pipeline.
    console.append(Data())
    #expect(console.version == v2)
}

@Test func serialConsoleVersionMonotonicUnderConcurrentAppend() async {
    let console = SerialConsole()
    let payload = Data("x\n".utf8)
    let perTask = 250
    let taskCount = 8

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<taskCount {
            group.addTask {
                for _ in 0..<perTask {
                    console.append(payload)
                }
            }
        }
    }

    // Every successful append bumped the counter exactly once.
    // Under the lock, this is the exact append count and nothing less.
    #expect(console.version == UInt64(taskCount * perTask))
}
