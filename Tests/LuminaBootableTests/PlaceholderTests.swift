// Tests/LuminaBootableTests/PlaceholderTests.swift
import Testing
@testable import LuminaBootable

@Test func moduleLoads() {
    #expect(LuminaBootableVersion.placeholder.hasPrefix("0.7.0"))
}
