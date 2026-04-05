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

@Test func parseDurationBareNumber() {
    #expect(parseDuration("30") == .seconds(30))
    #expect(parseDuration("0") == .seconds(0))
}

@Test func parseDurationInvalid() {
    #expect(parseDuration("banana") == nil)
    #expect(parseDuration("") == nil)
    #expect(parseDuration("s") == nil)
    #expect(parseDuration("m") == nil)
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
