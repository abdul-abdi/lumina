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
/// - Embedded bootpd can lose the first DHCP DISCOVER on a fresh install
///   (Debian/Kali netcfg's short single-probe timeout). Installer-side
///   workaround: "Retry network autoconfiguration" in the failure dialog.
/// - `VZBridgedNetworkDeviceAttachment` (see `BridgedNetworkProvider`)
///   sidesteps every item above by joining the guest to the host's LAN
///   directly and delegating DHCP to the user's real router.
public struct NATNetworkProvider: NetworkProvider {
    public init() {}

    public func createAttachment() throws -> VZNetworkDeviceAttachment {
        VZNATNetworkDeviceAttachment()
    }
}

/// Bridged attachment using `VZBridgedNetworkDeviceAttachment`. The guest
/// sits on the host's LAN directly, MAC visible on the segment, DHCP
/// served by the user's real router. Bypasses vmnet's NAT + embedded
/// bootpd entirely, which is the only reliable cure for the two
/// vmnet-induced failures documented on `NATNetworkProvider` above.
///
/// Requires `com.apple.vm.networking` at codesign time. Ad-hoc signing
/// accepts it without Apple developer-program approval — Apple only
/// reviews this entitlement for App Store / distribution builds. Without
/// the entitlement, `VZVirtualMachineConfiguration.validate()` rejects
/// the config with a specific error and the caller falls back to
/// `NATNetworkProvider` (the provider throws on construction failure,
/// callers handle it as a hard error per `NetworkProvider` contract).
///
/// Selection of the host interface:
/// - `interfaceIdentifier`: exact match on `VZBridgedNetworkInterface.identifier`
///   (e.g. `"en0"`). Caller's responsibility to pass a valid ID.
/// - `interfaceIdentifier == nil`: pick the first bridgeable interface
///   `VZBridgedNetworkInterface.networkInterfaces` advertises. Typical
///   result is `en0` on a Mac laptop with Wi-Fi.
///
/// If no bridgeable interface is available — e.g. the host has no active
/// network — construction throws `Error.noBridgeableInterface` so the UI
/// can surface a clear message.
public struct BridgedNetworkProvider: NetworkProvider {
    public let interfaceIdentifier: String?

    public enum Error: Swift.Error, Sendable {
        case noBridgeableInterface
        case interfaceNotFound(requested: String, available: [String])
    }

    public init(interfaceIdentifier: String? = nil) {
        self.interfaceIdentifier = interfaceIdentifier
    }

    public func createAttachment() throws -> VZNetworkDeviceAttachment {
        let candidates = VZBridgedNetworkInterface.networkInterfaces
        guard !candidates.isEmpty else {
            throw Error.noBridgeableInterface
        }
        let chosen: VZBridgedNetworkInterface
        if let requested = interfaceIdentifier {
            guard let match = candidates.first(where: { $0.identifier == requested }) else {
                throw Error.interfaceNotFound(
                    requested: requested,
                    available: candidates.map { $0.identifier }
                )
            }
            chosen = match
        } else {
            // First interface VZ enumerates. Order is typically en0 →
            // enN → awdlN; en0 is almost always what users want. If
            // they need something else they pass `interfaceIdentifier`.
            chosen = candidates[0]
        }
        return VZBridgedNetworkDeviceAttachment(interface: chosen)
    }

    /// Enumerate interface identifiers the host advertises as bridgeable.
    /// Callable from the UI to populate a "Network interface" picker.
    public static func availableInterfaceIdentifiers() -> [String] {
        VZBridgedNetworkInterface.networkInterfaces.map { $0.identifier }
    }
}
