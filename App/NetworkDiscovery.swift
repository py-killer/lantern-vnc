// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network
import Darwin

struct LANNetwork: Identifiable, Equatable {
    let interfaceName: String
    let address: String
    let netmask: String
    let prefixLength: Int
    let scanPrefixLength: Int
    let isPrivateAddress: Bool
    fileprivate let targets: [String]
    fileprivate let bindsLocalAddress: Bool

    var id: String { "\(interfaceName):\(address)/\(prefixLength)" }
    var displayName: String { "\(interfaceName) · \(address)/\(prefixLength)" }
    var targetCount: Int { targets.count }
    var isLimitedToLocalNeighborhood: Bool { scanPrefixLength > prefixLength }

    /// A safe planning initializer for private LANs; it performs no network I/O.
    init(interfaceName: String, address: String, netmask: String) throws {
        self = try NetworkPlan.make(interfaceName:interfaceName,address:address,netmask:netmask)
    }
    fileprivate init(interfaceName: String,address: String,netmask: String,prefixLength: Int,
                     scanPrefixLength: Int,isPrivateAddress: Bool,targets: [String],bindsLocalAddress: Bool) {
        self.interfaceName=interfaceName; self.address=address; self.netmask=netmask
        self.prefixLength=prefixLength; self.scanPrefixLength=scanPrefixLength
        self.isPrivateAddress=isPrivateAddress; self.targets=targets; self.bindsLocalAddress=bindsLocalAddress
    }
}

struct DiscoveredVNCServer: Identifiable, Equatable {
    let host: String
    let port: UInt16
    let protocolVersion: String
    var id: String { "\(host):\(port)" }
}

struct VNCDiscoveryProgress {
    let servers: [DiscoveredVNCServer]
    let completed: Int
    let total: Int
}

enum VNCDiscoveryError: LocalizedError {
    case interfacesUnavailable, invalidInterface, invalidAddress, invalidNetmask, invalidPort, noTargets
    var errorDescription: String? {
        switch self {
        case .interfacesUnavailable: return "Could not read the Mac’s network interfaces."
        case .invalidInterface: return "Choose an active Wi-Fi, Ethernet, or local bridge interface."
        case .invalidAddress: return "A valid private IPv4 LAN address is required."
        case .invalidNetmask: return "The IPv4 network mask is invalid."
        case .invalidPort: return "Enter one TCP port between 1 and 65535."
        case .noTargets: return "This network has no other IPv4 addresses to check."
        }
    }
}

protocol VNCDiscovering: AnyObject {
    func scan(network: LANNetwork,port: UInt16,
              onUpdate: @escaping (VNCDiscoveryProgress)->Void,
              onComplete: @escaping ([DiscoveredVNCServer])->Void) throws
    func cancel()
}

/// A bounded banner-only discovery service. It never authenticates or sends
/// application data. All public callbacks are delivered on the main queue.
final class VNCNetworkDiscovery: VNCDiscovering {
    private let worker=DiscoveryWorker()

    static func networks() throws -> [LANNetwork] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw VNCDiscoveryError.interfacesUnavailable }
        defer { if let list=list { freeifaddrs(list) } }
        var networks=[LANNetwork]()
        var item=list
        while let current=item {
            defer { item=current.pointee.ifa_next }
            let interface=current.pointee
            let flags=Int32(bitPattern:interface.ifa_flags)
            guard flags & IFF_UP != 0,flags & IFF_RUNNING != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let raw=interface.ifa_addr,raw.pointee.sa_family == UInt8(AF_INET),
                  let rawMask=interface.ifa_netmask else { continue }
            let name=String(cString:interface.ifa_name)
            guard NetworkPlan.isPhysicalName(name) else { continue }
            let address=UnsafeRawPointer(raw).assumingMemoryBound(to:sockaddr_in.self).pointee.sin_addr.s_addr
            let mask=UnsafeRawPointer(rawMask).assumingMemoryBound(to:sockaddr_in.self).pointee.sin_addr.s_addr
            let addressText=IPv4.text(UInt32(bigEndian:address))
            let maskText=IPv4.text(UInt32(bigEndian:mask))
            // Discovery is intentionally restricted to RFC1918 LANs. Public,
            // link-local, VPN and IPv6-only networks remain manual connections.
            guard let network=try? NetworkPlan.make(interfaceName:name,address:addressText,netmask:maskText),
                  network.targetCount > 0,!networks.contains(where:{$0.id == network.id}) else { continue }
            networks.append(network)
        }
        return networks.sorted {
            if $0.isPrivateAddress != $1.isPrivateAddress { return $0.isPrivateAddress }
            if $0.interfaceName.hasPrefix("en") != $1.interfaceName.hasPrefix("en") { return $0.interfaceName.hasPrefix("en") }
            return $0.id < $1.id
        }
    }

    static func planNetwork(interfaceName: String,address: String,netmask: String) throws -> LANNetwork {
        try LANNetwork(interfaceName:interfaceName,address:address,netmask:netmask)
    }

    func scan(network: LANNetwork,port: UInt16,
              onUpdate: @escaping (VNCDiscoveryProgress)->Void,
              onComplete: @escaping ([DiscoveredVNCServer])->Void) throws {
        guard port > 0 else { throw VNCDiscoveryError.invalidPort }
        guard !network.targets.isEmpty else { throw VNCDiscoveryError.noTargets }
        worker.begin(network:network,port:port,onUpdate:onUpdate,onComplete:onComplete)
    }
    /// Invalidates queued callbacks synchronously; socket teardown is queued on
    /// the worker. No completion callback is sent for a canceled scan.
    func cancel() { worker.cancel() }
    deinit { worker.cancel() }

    #if NETWORK_DISCOVERY_TESTS
    /// Test builds may scan explicitly supplied loopback addresses only.
    static func testNetwork(targets: [String]) throws -> LANNetwork {
        guard !targets.isEmpty,targets.count <= 256,
              targets.allSatisfy({ IPv4.parse($0).map { $0 >> 24 == 127 } ?? false }) else {
            throw VNCDiscoveryError.invalidAddress
        }
        return LANNetwork(interfaceName:"lo0-test",address:"127.0.0.1",netmask:"255.0.0.0",
                          prefixLength:8,scanPrefixLength:24,isPrivateAddress:false,
                          targets:Array(Set(targets)).sorted(),bindsLocalAddress:false)
    }
    #endif
}

private enum IPv4 {
    static func parse(_ text: String) -> UInt32? {
        var address=in_addr()
        guard text.withCString({inet_pton(AF_INET,$0,&address)}) == 1 else { return nil }
        return UInt32(bigEndian:address.s_addr)
    }
    static func text(_ value: UInt32) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }
    static func isPrivate(_ value: UInt32) -> Bool {
        value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8
    }
    static func isUsable(_ value: UInt32) -> Bool {
        value >> 24 != 0 && value >> 24 != 127 && value >> 16 != 0xA9FE && value >> 28 < 14
    }
}

private enum NetworkPlan {
    static func isPhysicalName(_ name: String) -> Bool {
        let suffix: Substring
        if name.hasPrefix("en") { suffix=name.dropFirst(2) }
        else if name.hasPrefix("bridge") { suffix=name.dropFirst(6) }
        else { return false }
        return !suffix.isEmpty && suffix.allSatisfy({$0.isASCII && $0.isNumber})
    }
    static func make(interfaceName: String,address: String,netmask: String) throws -> LANNetwork {
        guard isPhysicalName(interfaceName) else { throw VNCDiscoveryError.invalidInterface }
        guard let value=IPv4.parse(address),IPv4.isUsable(value),IPv4.isPrivate(value) else {
            throw VNCDiscoveryError.invalidAddress
        }
        guard let mask=IPv4.parse(netmask) else { throw VNCDiscoveryError.invalidNetmask }
        let inverse = ~mask
        guard inverse & (inverse &+ 1) == 0 else { throw VNCDiscoveryError.invalidNetmask }
        let prefix=mask.nonzeroBitCount
        let scanPrefix=max(24,prefix)
        let scanMask=UInt32.max << (32-scanPrefix)
        let first=value & scanMask,last=first | ~scanMask
        let actualFirst=value & mask,actualLast=actualFirst | ~mask
        // A .0/.255 inside an artificial /24 may be a valid host in the
        // interface's wider real subnet. Exclude only its actual endpoints.
        let lower=max(UInt64(first),UInt64(actualFirst)+(prefix <= 30 ? 1 : 0))
        let upper=min(UInt64(last),UInt64(actualLast)-(prefix <= 30 ? 1 : 0))
        var targets=[String]()
        if lower <= upper {
            for host in lower...upper where host != UInt64(value) { targets.append(IPv4.text(UInt32(host))) }
        }
        return LANNetwork(interfaceName:interfaceName,address:IPv4.text(value),netmask:IPv4.text(mask),
                          prefixLength:prefix,scanPrefixLength:scanPrefix,isPrivateAddress:IPv4.isPrivate(value),
                          targets:targets,bindsLocalAddress:true)
    }
}

/// The callback gate also serializes cancellation against an in-flight callback.
/// Its recursive lock lets a main-queue callback safely cancel or restart a scan.
private final class CallbackGate {
    private let lock=NSRecursiveLock()
    private var generation: UInt64=0
    func invalidate() -> UInt64 { lock.lock(); defer { lock.unlock() }; generation &+= 1; return generation }
    func contains(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == token }
    func deliver(_ token: UInt64,_ callback: @escaping ()->Void) {
        DispatchQueue.main.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard generation == token else { return }
            callback()
        }
    }
}

private final class DiscoveryProbe {
    let id=UUID()
    let host: String
    let connection: NWConnection
    var bytes=Data()
    var deadline: DispatchWorkItem?
    var finished=false
    init(host: String,connection: NWConnection) { self.host=host; self.connection=connection }
    func close() { deadline?.cancel(); connection.stateUpdateHandler=nil; connection.cancel() }
}

private final class DiscoveryScan {
    let token: UInt64,network: LANNetwork,port: UInt16
    let onUpdate: (VNCDiscoveryProgress)->Void
    let onComplete: ([DiscoveredVNCServer])->Void
    var next=0,completed=0
    var probes=[UUID:DiscoveryProbe]()
    var servers=[DiscoveredVNCServer]()
    init(token: UInt64,network: LANNetwork,port: UInt16,
         onUpdate: @escaping (VNCDiscoveryProgress)->Void,onComplete: @escaping ([DiscoveredVNCServer])->Void) {
        self.token=token; self.network=network; self.port=port; self.onUpdate=onUpdate; self.onComplete=onComplete
    }
}

private final class DiscoveryWorker {
    private let queue=DispatchQueue(label:"local.lantern.vnc.discovery",qos:.utility)
    private let gate=CallbackGate()
    private var active: DiscoveryScan?

    func begin(network: LANNetwork,port: UInt16,onUpdate: @escaping (VNCDiscoveryProgress)->Void,
               onComplete: @escaping ([DiscoveredVNCServer])->Void) {
        let token=gate.invalidate()
        queue.async { [self] in
            guard gate.contains(token) else { return }
            stopActive()
            let scan=DiscoveryScan(token:token,network:network,port:port,onUpdate:onUpdate,onComplete:onComplete)
            active=scan; publish(scan); pump(scan)
        }
    }
    func cancel() {
        let token=gate.invalidate()
        queue.async { [self] in if gate.contains(token) { stopActive() } }
    }
    private func stopActive() {
        if let scan=active { for probe in scan.probes.values { probe.close() }; scan.probes.removeAll() }
        active=nil
    }
    private func publish(_ scan: DiscoveryScan) {
        let progress=VNCDiscoveryProgress(servers:sorted(scan.servers),completed:scan.completed,total:scan.network.targetCount)
        gate.deliver(scan.token) { scan.onUpdate(progress) }
    }
    private func sorted(_ servers: [DiscoveredVNCServer]) -> [DiscoveredVNCServer] {
        servers.sorted { (IPv4.parse($0.host) ?? 0) < (IPv4.parse($1.host) ?? 0) }
    }
    private func pump(_ scan: DiscoveryScan) {
        guard active === scan,gate.contains(scan.token) else { return }
        while scan.probes.count < 32,scan.next < scan.network.targets.count {
            let host=scan.network.targets[scan.next]; scan.next += 1
            let parameters=NWParameters.tcp
            if scan.network.bindsLocalAddress {
                parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(scan.network.address),port:.any)
            }
            let connection=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:scan.port)!,using:parameters)
            let probe=DiscoveryProbe(host:host,connection:connection)
            scan.probes[probe.id]=probe
            let deadline=DispatchWorkItem { [weak self,weak scan,weak probe] in
                guard let self=self,let scan=scan,let probe=probe else { return }
                self.finish(probe,in:scan,version:nil)
            }
            probe.deadline=deadline
            queue.asyncAfter(deadline:.now()+1,execute:deadline)
            connection.stateUpdateHandler = { [weak self,weak scan,weak probe] state in
                guard let self=self,let scan=scan,let probe=probe else { return }
                switch state {
                case .ready: self.receive(probe,in:scan)
                case .failed,.cancelled: self.finish(probe,in:scan,version:nil)
                default: break
                }
            }
            connection.start(queue:queue)
        }
        if scan.next == scan.network.targets.count,scan.probes.isEmpty {
            active=nil
            let servers=sorted(scan.servers)
            gate.deliver(scan.token) { scan.onComplete(servers) }
        }
    }
    private func receive(_ probe: DiscoveryProbe,in scan: DiscoveryScan) {
        guard !probe.finished,active === scan,gate.contains(scan.token) else { return }
        probe.connection.receive(minimumIncompleteLength:1,maximumLength:12-probe.bytes.count) { [weak self,weak scan,weak probe] data,_,complete,error in
            guard let self=self,let scan=scan,let probe=probe,!probe.finished else { return }
            if let data=data { probe.bytes.append(data) }
            if probe.bytes.count == 12 {
                let bytes=Array(probe.bytes)
                let digits=[4,5,6,8,9,10].allSatisfy { (48...57).contains(bytes[$0]) }
                let valid=Array(bytes[0..<4]) == [82,70,66,32] && bytes[7] == 46 && bytes[11] == 10 && digits
                self.finish(probe,in:scan,version:valid ? String(bytes:bytes[4..<11],encoding:.ascii) : nil)
            } else if complete || error != nil { self.finish(probe,in:scan,version:nil) }
            else { self.receive(probe,in:scan) }
        }
    }
    private func finish(_ probe: DiscoveryProbe,in scan: DiscoveryScan,version: String?) {
        guard !probe.finished else { return }
        probe.finished=true; probe.close()
        guard active === scan,gate.contains(scan.token) else { return }
        scan.probes.removeValue(forKey:probe.id); scan.completed += 1
        if let version=version { scan.servers.append(DiscoveredVNCServer(host:probe.host,port:scan.port,protocolVersion:version)) }
        publish(scan); pump(scan)
    }
}
