// Sources/Lumina/NetworkProvider.swift
@preconcurrency import Virtualization

/// Abstraction over network attachment creation. Allows swapping
/// VZNATNetworkDeviceAttachment for VZFileHandleNetworkDeviceAttachment
/// (or other implementations) without modifying the VM actor.
public protocol NetworkProvider: Sendable {
    func createAttachment() throws -> VZNetworkDeviceAttachment
}

/// Default provider using macOS vmnet NAT (VZNATNetworkDeviceAttachment).
/// Zero config, no entitlements required. Known limitations:
/// - UDP to external IPs is unreliable (vmnet PF NAT)
/// - InternetSharing may degrade after ~5 VM lifecycles per session
/// - ICMP to external IPs is unreliable
public struct NATNetworkProvider: NetworkProvider {
    public init() {}

    public func createAttachment() throws -> VZNetworkDeviceAttachment {
        VZNATNetworkDeviceAttachment()
    }
}
