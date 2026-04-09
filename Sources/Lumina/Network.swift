// Sources/Lumina/Network.swift
import Foundation

/// Manages a group of VMs on a shared private network.
/// All VMs are booted within a single process — no cross-process networking.
public actor Network {
    private let name: String
    private let networkSwitch: NetworkSwitch
    private var sessions: [(name: String, ip: String, vm: VM)] = []

    public init(name: String) {
        self.name = name
        self.networkSwitch = NetworkSwitch()
    }

    /// Boot a new VM on the network.
    public func session(
        name sessionName: String,
        image: String = "default",
        options: VMOptions = .default
    ) async throws -> VM {
        let index = sessions.count
        let ip = NetworkSwitch.ipForIndex(index)

        let port = try networkSwitch.createPort()

        var allPeers = sessions.map { ($0.name, $0.ip) }
        allPeers.append((sessionName, ip))
        let hostsMap = Dictionary(uniqueKeysWithValues: allPeers.map { ($0.0, $0.1) })

        var vmOpts = options
        vmOpts.image = image
        vmOpts.privateNetworkFd = port.vmFd
        vmOpts.networkHosts = hostsMap
        vmOpts.networkIP = ip

        let vm = VM(options: vmOpts)
        try await vm.bootResult().get()

        sessions.append((name: sessionName, ip: ip, vm: vm))

        if sessions.count == 2 {
            networkSwitch.startRelay()
        }

        return vm
    }

    /// Shutdown all VMs and close the network.
    public func shutdown() async {
        for (_, _, vm) in sessions {
            await vm.shutdown()
        }
        networkSwitch.close()
        sessions = []
    }
}
