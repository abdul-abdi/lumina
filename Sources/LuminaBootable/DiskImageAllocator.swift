// Sources/LuminaBootable/DiskImageAllocator.swift
//
// Creates sparse disk image files for use as
// `VZDiskImageStorageDeviceAttachment` backing storage.
//
// The file is created via `open(O_CREAT | O_EXCL)` + `ftruncate` so the
// logical size matches the requested capacity but the on-disk footprint
// stays near zero until the guest writes into the sparse region. APFS on
// macOS 14+ hosts keeps this file genuinely sparse.

import Foundation
import Darwin

public enum DiskImageAllocator {
    public enum Error: Swift.Error, Equatable {
        case fileExists(URL)
        case zeroSize
        case openFailed(URL, errno: Int32)
        case ftruncateFailed(URL, errno: Int32)
    }

    /// Create a sparse file of `logicalSize` bytes at `url`.
    ///
    /// Throws if the file already exists or if `logicalSize == 0`. On
    /// `ftruncate` failure the partially-created file is removed before
    /// rethrowing so the caller doesn't need to clean up on error.
    public static func allocate(at url: URL, logicalSize: UInt64) throws {
        guard logicalSize > 0 else { throw Error.zeroSize }
        if FileManager.default.fileExists(atPath: url.path) {
            throw Error.fileExists(url)
        }
        let fd = url.path.withCString { cPath in
            Darwin.open(cPath, O_CREAT | O_EXCL | O_RDWR, 0o644)
        }
        if fd < 0 { throw Error.openFailed(url, errno: errno) }
        defer { Darwin.close(fd) }
        if ftruncate(fd, off_t(logicalSize)) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: url)
            throw Error.ftruncateFailed(url, errno: err)
        }
    }
}
