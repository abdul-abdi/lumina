// Sources/lumina-cli/main.swift
import ArgumentParser
import Foundation
import Lumina

@main
struct LuminaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lumina",
        abstract: "Native Apple Workload Runtime for Agents — subprocess.run() for virtual machines.",
        version: "0.1.0",
        subcommands: [Run.self, Pull.self, Images.self, Clean.self]
    )
}

// MARK: - Run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a disposable VM")

    @Argument(help: "Command to run in the VM")
    var command: String

    @Flag(name: .long, help: "Stream stdout/stderr in real time")
    var stream = false

    @Option(name: .long, help: "Timeout (e.g. 30s, 5m)")
    var timeout: String = "60s"

    @Option(name: .long, help: "Memory (e.g. 512MB, 1GB)")
    var memory: String = "512MB"

    @Option(name: .long, help: "Number of CPU cores")
    var cpus: Int = 2

    func run() async throws {
        // Auto-pull image if not present
        let puller = ImagePuller()
        if !puller.imageExists() {
            FileHandle.standardError.write(Data("Image not found. Pulling default image...\n".utf8))
            do {
                try await puller.pull { msg in
                    FileHandle.standardError.write(Data("\(msg)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("lumina: auto-pull failed: \(error)\n".utf8))
                FileHandle.standardError.write(Data("Build locally: cd Guest && sudo ./build-image.sh\n".utf8))
                throw ExitCode.failure
            }
        }

        let options = RunOptions(
            timeout: parseDuration(timeout),
            memory: parseMemory(memory),
            cpuCount: cpus
        )

        if stream {
            let chunks = Lumina.stream(command, options: options)
            for try await chunk in chunks {
                switch chunk {
                case .stdout(let data):
                    print(data, terminator: "")
                case .stderr(let data):
                    FileHandle.standardError.write(Data(data.utf8))
                case .exit(let code):
                    if code != 0 {
                        throw ExitCode(code)
                    }
                }
            }
        } else {
            do {
                let result = try await Lumina.run(command, options: options)
                print(result.stdout, terminator: "")
                if !result.stderr.isEmpty {
                    FileHandle.standardError.write(Data(result.stderr.utf8))
                }
                if !result.success {
                    throw ExitCode(result.exitCode)
                }
            } catch let error as LuminaError {
                switch error {
                case .guestCrashed(let serialOutput):
                    FileHandle.standardError.write(Data("lumina: guest crashed\n--- serial output ---\n\(serialOutput)\n--- end serial ---\n".utf8))
                default:
                    FileHandle.standardError.write(Data("lumina: \(error)\n".utf8))
                }
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Pull

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull the default Alpine image from GitHub Releases")

    @Flag(name: .long, help: "Re-download even if image already exists")
    var force = false

    func run() async throws {
        let puller = ImagePuller()

        if puller.imageExists() && !force {
            print("Image 'default' already exists. Use --force to re-download.")
            return
        }

        if puller.imageExists() && force {
            // Remove existing image before re-pulling
            ImageStore().clean(name: "default")
        }

        do {
            try await puller.pull { msg in
                print(msg)
            }
            print("Done! Run 'lumina run \"echo hello\"' to test.")
        } catch {
            FileHandle.standardError.write(Data("lumina pull: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

// MARK: - Images

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List cached images")

    func run() throws {
        let store = ImageStore()
        let names = store.list()
        if names.isEmpty {
            print("No images found. Run 'lumina pull' first.")
        } else {
            for name in names {
                print(name)
            }
        }
    }
}

// MARK: - Clean

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove orphaned COW clones and stale images")

    func run() throws {
        let removed = DiskClone.cleanOrphans()
        if removed > 0 {
            print("Removed \(removed) orphaned clone(s).")
        } else {
            print("No orphaned clones found.")
        }
    }
}

// MARK: - Parsing Helpers

func parseDuration(_ str: String) -> Duration {
    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.hasSuffix("s") {
        let num = Int(trimmed.dropLast()) ?? 60
        return .seconds(num)
    } else if trimmed.hasSuffix("m") {
        let num = Int(trimmed.dropLast()) ?? 1
        return .seconds(num * 60)
    }
    return .seconds(Int(trimmed) ?? 60)
}

func parseMemory(_ str: String) -> UInt64 {
    let trimmed = str.trimmingCharacters(in: .whitespaces).uppercased()
    if trimmed.hasSuffix("GB") {
        let num = UInt64(trimmed.dropLast(2)) ?? 1
        return num * 1024 * 1024 * 1024
    } else if trimmed.hasSuffix("MB") {
        let num = UInt64(trimmed.dropLast(2)) ?? 512
        return num * 1024 * 1024
    }
    return UInt64(trimmed) ?? 512 * 1024 * 1024
}
