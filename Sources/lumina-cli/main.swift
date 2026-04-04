// Sources/lumina-cli/main.swift
import ArgumentParser

@main
struct LuminaCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lumina",
        abstract: "Native Apple Workload Runtime for Agents",
        version: "0.1.0",
        subcommands: [Run.self, Pull.self, Images.self, Clean.self]
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a disposable VM")

    @Argument(help: "Command to run in the VM")
    var command: String

    func run() throws {
        print("lumina run: not yet implemented")
    }
}

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull the default Alpine image")
    func run() throws { print("lumina pull: not yet implemented") }
}

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List cached images")
    func run() throws { print("lumina images: not yet implemented") }
}

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove orphaned COW clones and stale images")
    func run() throws { print("lumina clean: not yet implemented") }
}
