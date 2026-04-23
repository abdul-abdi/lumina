// Tests/LuminaBootableTests/AgentImageCatalogTests.swift
//
// The agent-image catalog ships stable identity (id + url) but the
// sha256 values are placeholders until the CI build-baked-image.yml
// workflow publishes real artifacts. These tests verify the schema
// and lookup API, NOT the sha256 values — those are tested end-to-end
// at pull time.

import Foundation
import Testing
@testable import LuminaBootable

@Suite struct AgentImageCatalogTests {

    @Test func catalogNotEmpty() {
        #expect(!AgentImageCatalog.all.isEmpty)
    }

    @Test func idsAreUnique() {
        let ids = AgentImageCatalog.all.map { $0.id }
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count,
                "duplicate image id in catalog: \(ids)")
    }

    @Test func lookupByIdRoundTrips() {
        for entry in AgentImageCatalog.all {
            let found = AgentImageCatalog.entry(id: entry.id)
            #expect(found == entry, "lookup failed for id=\(entry.id)")
        }
    }

    @Test func lookupByUnknownIdReturnsNil() {
        #expect(AgentImageCatalog.entry(id: "does-not-exist") == nil)
    }

    @Test func tagsAreLowercaseFriendly() {
        // Regression guard: filtering is case-insensitive so a mixed-
        // case tag in data doesn't break the Desktop tag picker.
        for entry in AgentImageCatalog.all {
            for tag in entry.tags {
                let found = AgentImageCatalog.entries(withTag: tag.uppercased())
                #expect(found.contains(entry),
                        "entry \(entry.id) missing from uppercase filter for tag=\(tag)")
            }
        }
    }

    @Test func everyURLIsHTTPS() {
        // Security: the catalog must not ship an http:// URL. Pull
        // verification rests on TLS + sha256; http weakens both.
        for entry in AgentImageCatalog.all {
            #expect(entry.url.scheme == "https",
                    "entry \(entry.id) has non-https url: \(entry.url)")
        }
    }

    @Test func defaultBakedEntryPresent() {
        // v0.7.1 foundation: the default-baked entry is the curated
        // fast-path image. Removing it would break the Desktop app's
        // "use baked image for faster cold boot" button (future UI).
        #expect(AgentImageCatalog.entry(id: "default-baked") != nil)
    }
}
