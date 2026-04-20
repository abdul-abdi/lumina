// Tests/LuminaTests/ParsingTests.swift
import Testing
@testable import Lumina

@Test func parseDurationSeconds() {
    #expect(parseDuration("30s") == .seconds(30))
    #expect(parseDuration("0s") == .seconds(0))
    #expect(parseDuration("120s") == .seconds(120))
}

@Test func parseDurationMinutes() {
    #expect(parseDuration("5m") == .seconds(300))
    #expect(parseDuration("1m") == .seconds(60))
}

@Test func parseDurationHours() {
    #expect(parseDuration("1h") == .seconds(3600))
    #expect(parseDuration("2h") == .seconds(7200))
    #expect(parseDuration("24h") == .seconds(86400))
}

@Test func parseDurationBareNumber() {
    #expect(parseDuration("30") == .seconds(30))
    #expect(parseDuration("0") == .seconds(0))
}

@Test func parseDurationInvalid() {
    #expect(parseDuration("banana") == nil)
    #expect(parseDuration("") == nil)
    #expect(parseDuration("s") == nil)
    #expect(parseDuration("m") == nil)
    #expect(parseDuration("h") == nil)
    #expect(parseDuration("12x") == nil)
}

@Test func parseMemoryMB() {
    #expect(parseMemory("512MB") == 512 * 1024 * 1024)
    #expect(parseMemory("1MB") == 1024 * 1024)
    #expect(parseMemory("512mb") == 512 * 1024 * 1024)
}

@Test func parseMemoryGB() {
    #expect(parseMemory("1GB") == 1024 * 1024 * 1024)
    #expect(parseMemory("4GB") == UInt64(4) * 1024 * 1024 * 1024)
    #expect(parseMemory("1gb") == 1024 * 1024 * 1024)
}

@Test func parseMemoryRejectsBarNumber() {
    #expect(parseMemory("512") == nil)
    #expect(parseMemory("1024") == nil)
}

@Test func parseMemoryRejectsInvalid() {
    #expect(parseMemory("lots") == nil)
    #expect(parseMemory("") == nil)
    #expect(parseMemory("0MB") == nil)
    #expect(parseMemory("0GB") == nil)
    #expect(parseMemory("MB") == nil)
    #expect(parseMemory("-1MB") == nil)
}

// MARK: - parseForwardSpec

@Test func parseForwardSpecBasic() {
    #expect(parseForwardSpec("8080:80") == ForwardSpec(hostPort: 8080, guestPort: 80))
    #expect(parseForwardSpec("5432:5432") == ForwardSpec(hostPort: 5432, guestPort: 5432))
}

@Test func parseForwardSpecBoundary() {
    #expect(parseForwardSpec("1:1") == ForwardSpec(hostPort: 1, guestPort: 1))
    #expect(parseForwardSpec("65535:65535") == ForwardSpec(hostPort: 65535, guestPort: 65535))
}

@Test func parseForwardSpecInvalid() {
    #expect(parseForwardSpec("") == nil)
    #expect(parseForwardSpec("8080") == nil)            // no colon
    #expect(parseForwardSpec(":80") == nil)             // empty host
    #expect(parseForwardSpec("8080:") == nil)           // empty guest
    #expect(parseForwardSpec("8080:80:1") == nil)       // extra colon
    #expect(parseForwardSpec("0:80") == nil)            // zero host port
    #expect(parseForwardSpec("80:0") == nil)            // zero guest port
    #expect(parseForwardSpec("65536:80") == nil)        // host overflow
    #expect(parseForwardSpec("80:65536") == nil)        // guest overflow
    #expect(parseForwardSpec("-1:80") == nil)           // negative
    #expect(parseForwardSpec("abc:80") == nil)          // not a number
    #expect(parseForwardSpec("80:abc") == nil)          // not a number
}
