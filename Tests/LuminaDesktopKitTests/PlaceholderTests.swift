// Tests/LuminaDesktopKitTests/PlaceholderTests.swift
import Testing
@testable import LuminaDesktopKit

@Test func moduleLoads() {
    #expect(LuminaDesktopKitVersion.placeholder.hasPrefix("0.7.0"))
}
