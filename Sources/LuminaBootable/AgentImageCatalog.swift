// Sources/LuminaBootable/AgentImageCatalog.swift
//
// Catalog of pre-built agent-path images hosted on GitHub Releases.
// This is the "curated list" analog of DesktopOSCatalog — the CLI
// wizard and Desktop app both surface entries from here.
//
// v0.7.1 ships the catalog surface; pulls still happen manually via
// `lumina images pull <url>` (future). The entries define stable
// identity (name + sha256 + url), which is what `images create`
// and `Lumina.run --image <name>` need to resolve.
//
// Adding an image:
//   1. Publish `lumina-image-<name>.tar.gz` as a Lumina Release asset.
//   2. Compute its SHA-256.
//   3. Add an entry here.
//   4. Tests in AgentImageCatalogTests pin the sha256 so mirror drift
//      is caught at commit time.

import Foundation

/// A curated agent-path image hosted on the Lumina GitHub Releases.
public struct AgentImageEntry: Sendable, Equatable {
    /// Short identifier — what users type in `--image <id>`.
    public let id: String
    /// Human-readable name shown in the Desktop "Agent Images" sidebar.
    public let displayName: String
    /// One-sentence summary of what this image is good for.
    public let summary: String
    /// Download URL for the tarball. Stable GitHub Release asset URL.
    public let url: URL
    /// Lowercase hex SHA-256 of the tarball. Verified via
    /// `ISOVerifier.sha256Hex` before extraction.
    public let sha256: String
    /// Uncompressed size hint (bytes), for progress UIs. Rounded; not
    /// a correctness gate.
    public let approximateSize: Int64
    /// Tags for filtering in the Desktop picker ("agent", "build",
    /// "ml", etc.). Free-form.
    public let tags: [String]

    public init(
        id: String,
        displayName: String,
        summary: String,
        url: URL,
        sha256: String,
        approximateSize: Int64,
        tags: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.url = url
        self.sha256 = sha256
        self.approximateSize = approximateSize
        self.tags = tags
    }
}

public enum AgentImageCatalog {
    /// All curated entries. Sorted by id for deterministic ordering in
    /// the Desktop sidebar.
    public static let all: [AgentImageEntry] = [
        // Baked-kernel rebuild of the default Alpine image. Ships with
        // the v0.7.1 release asset from the build-baked-image.yml
        // workflow. ~150 ms faster cold-boot than the legacy default.
        AgentImageEntry(
            id: "default-baked",
            displayName: "Alpine (baked kernel)",
            summary: "Alpine minimal rootfs with a custom CONFIG_MODULES=n kernel. ~150ms faster cold-boot than the legacy default; no initrd, no module loading.",
            url: URL(string: "https://github.com/abdul-abdi/lumina/releases/latest/download/lumina-image-default-baked.tar.gz")!,
            // NB: placeholder. Update via
            // `sha256sum lumina-image-default-baked.tar.gz` after the
            // CI build-baked-image.yml workflow publishes it. The
            // catalog pull path refuses any tarball whose digest
            // doesn't match.
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            approximateSize: 300 * 1024 * 1024,
            tags: ["agent", "baseline", "baked"]
        ),

        // Below are the "foundation for crazy ideas" entries — the
        // images aren't published yet, but the identity is stable so
        // users / CI can reference them before the artifact lands.
        // Updating the sha256 (via a tagged release) unlocks pulls.

        // OpenClaw — sandbox for cross-compilation + pentesting tools.
        // Think Kali-minimal with the OpenClaw tool suite pre-seeded.
        AgentImageEntry(
            id: "openclaw",
            displayName: "OpenClaw (agent path)",
            summary: "Cross-compiler + pentest toolchain baked into an Alpine rootfs. For agents that need to run untrusted code against a full tool bench.",
            url: URL(string: "https://github.com/abdul-abdi/lumina/releases/latest/download/lumina-image-openclaw.tar.gz")!,
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            approximateSize: 800 * 1024 * 1024,
            tags: ["agent", "security", "tooling"]
        ),

        // Hermes agents — Python + CUDA shims for ML-agent workloads.
        AgentImageEntry(
            id: "hermes",
            displayName: "Hermes (ML-agent)",
            summary: "Alpine + Python 3.12 + ML toolchain shims. For agents that orchestrate ML experiments against remote inference endpoints.",
            url: URL(string: "https://github.com/abdul-abdi/lumina/releases/latest/download/lumina-image-hermes.tar.gz")!,
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            approximateSize: 600 * 1024 * 1024,
            tags: ["agent", "ml", "python"]
        ),
    ]

    /// Look up an entry by its short id.
    public static func entry(id: String) -> AgentImageEntry? {
        all.first { $0.id == id }
    }

    /// Filter entries by tag (case-insensitive).
    public static func entries(withTag tag: String) -> [AgentImageEntry] {
        let needle = tag.lowercased()
        return all.filter { $0.tags.contains(where: { $0.lowercased() == needle }) }
    }
}
