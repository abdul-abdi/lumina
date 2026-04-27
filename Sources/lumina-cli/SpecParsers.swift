// Sources/lumina-cli/SpecParsers.swift
//
// Shared parsers for CLI flag specs that more than one subcommand
// accepts: `--env KEY=VAL`, `--copy local:remote`,
// `--download remote:local`, `--volume name_or_path:guest`.
//
// Each helper writes a friendly error to stderr and throws
// `ExitCode.failure` on bad input — same shape as the inline parsers
// they replace, so subcommand callers don't need their own error
// formatting. Audit follow-up: the duplication between `Run` and
// `pool run` was ~80 LOC of identical loops.
import ArgumentParser
import Foundation
import Lumina

/// Parse `KEY=VAL` env-var specs. Empty input is allowed (returns
/// empty map); a missing `=` is a hard error.
func parseEnvSpecs(_ specs: [String]) throws -> [String: String] {
    var parsed: [String: String] = [:]
    for pair in specs {
        guard let eqIndex = pair.firstIndex(of: "=") else {
            FileHandle.standardError.write(Data("lumina: invalid env '\(pair)'. Use KEY=VAL format\n".utf8))
            throw ExitCode.failure
        }
        let key = String(pair[pair.startIndex..<eqIndex])
        let value = String(pair[pair.index(after: eqIndex)...])
        parsed[key] = value
    }
    return parsed
}

/// Parse `--copy local:remote` specs. Auto-detects file vs directory
/// from the local path; throws if the local path doesn't exist.
/// Returns the two-bucket split that callers thread into
/// `RunOptions.uploads` and `RunOptions.directoryUploads`.
func parseCopySpecs(_ specs: [String]) throws -> ([FileUpload], [DirectoryUpload]) {
    var files: [FileUpload] = []
    var dirs: [DirectoryUpload] = []
    for spec in specs {
        guard let colonIndex = spec.firstIndex(of: ":") else {
            FileHandle.standardError.write(Data("lumina: invalid --copy '\(spec)'. Use local:remote format\n".utf8))
            throw ExitCode.failure
        }
        let localStr = String(spec[spec.startIndex..<colonIndex])
        let remote = String(spec[spec.index(after: colonIndex)...])
        let localURL = URL(fileURLWithPath: localStr)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir) else {
            FileHandle.standardError.write(Data("lumina: not found: \(localStr)\n".utf8))
            throw ExitCode.failure
        }
        if isDir.boolValue {
            dirs.append(DirectoryUpload(localPath: localURL, remotePath: remote))
        } else {
            let mode = FileManager.default.isExecutableFile(atPath: localURL.path) ? "0755" : "0644"
            files.append(FileUpload(localPath: localURL, remotePath: remote, mode: mode))
        }
    }
    return (files, dirs)
}

/// Parse `--download remote:local` specs. Path existence is not
/// checked here — the guest decides at runtime whether the remote
/// path is a file or directory.
func parseDownloadSpecs(_ specs: [String]) throws -> [FileDownload] {
    var parsed: [FileDownload] = []
    for spec in specs {
        guard let colonIndex = spec.firstIndex(of: ":") else {
            FileHandle.standardError.write(Data("lumina: invalid --download '\(spec)'. Use remote:local format\n".utf8))
            throw ExitCode.failure
        }
        let remote = String(spec[spec.startIndex..<colonIndex])
        let localStr = String(spec[spec.index(after: colonIndex)...])
        let localURL = URL(fileURLWithPath: localStr)
        parsed.append(FileDownload(remotePath: remote, localPath: localURL))
    }
    return parsed
}

/// Parse `--volume name_or_path:guest` specs.
///
/// Disambiguation: a leading `/` or `.` means "host directory mount"
/// (the path must exist and be a directory). Anything else is
/// resolved against the named-volume store.
func parseVolumeSpecs(_ specs: [String], volumeStore: VolumeStore) throws -> [MountPoint] {
    var parsed: [MountPoint] = []
    for spec in specs {
        guard let colonIndex = spec.firstIndex(of: ":") else {
            FileHandle.standardError.write(Data("lumina: invalid --volume '\(spec)'. Use path_or_name:guest_path\n".utf8))
            throw ExitCode.failure
        }
        let left = String(spec[spec.startIndex..<colonIndex])
        let guestPath = String(spec[spec.index(after: colonIndex)...])

        if left.hasPrefix("/") || left.hasPrefix(".") {
            let hostURL = URL(fileURLWithPath: left)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir), isDir.boolValue else {
                FileHandle.standardError.write(Data("lumina: not a directory: \(left)\n".utf8))
                throw ExitCode.failure
            }
            parsed.append(MountPoint(hostPath: hostURL, guestPath: guestPath))
        } else {
            guard let hostDir = volumeStore.resolve(name: left) else {
                FileHandle.standardError.write(Data("lumina: volume '\(left)' not found\n".utf8))
                throw ExitCode.failure
            }
            volumeStore.touch(name: left)
            parsed.append(MountPoint(hostPath: hostDir, guestPath: guestPath))
        }
    }
    return parsed
}
