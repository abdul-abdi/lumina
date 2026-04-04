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
