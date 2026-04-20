// Tests/LuminaGraphicsTests/PlaceholderTests.swift
import Testing
@testable import LuminaGraphics

@Test func moduleLoads() {
    #expect(LuminaGraphicsVersion.placeholder.hasPrefix("0.7.0"))
}
