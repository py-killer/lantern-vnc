// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// This fixture can bind only IPv4 loopback. It sends a banner and records any
/// unexpected bytes; it never performs VNC authentication or sends input.
private final class LoopbackVNCServer {
    enum Banner {
        case valid, partial, malformed, silent
        var pieces: [Data] {
            switch self {
            case .valid: return [Data("RFB 003.008\n".utf8)]
            case .partial: return [Data("RFB ".utf8), Data("003.".utf8), Data("008\n".utf8)]
            case .malformed: return [Data("HTTP/1.1 200 OK\r\n".utf8)]
            case .silent: return []
            }
        }
    }

    let port: UInt16
    private let listener: Int32
    private let banners: [Banner]
    private let lock = NSLock()
    private var stopped = false
    private var clientSockets = Set<Int32>()
    private var acceptedCount = 0
    private var incomingCount = 0

    var acceptedConnections: Int { lock.lock(); defer { lock.unlock() }; return acceptedCount }
    var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return clientSockets.count }
    var receivedBytes: Int { lock.lock(); defer { lock.unlock() }; return incomingCount }

    init(_ banners: [Banner]) throws {
        precondition(!banners.isEmpty)
        self.banners = banners
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        guard fd >= 0 else { throw Self.failure("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let error = Self.failure("loopback bind"); Darwin.close(fd); throw error }
        guard Darwin.listen(fd, 16) == 0 else { let error = Self.failure("listen"); Darwin.close(fd); throw error }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &addressLength) }
        }
        guard named == 0 else { let error = Self.failure("getsockname"); Darwin.close(fd); throw error }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        DispatchQueue.global(qos: .userInitiated).async { [self] in acceptLoop() }
    }

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }

    func stop() {
        lock.lock()
        stopped = true
        let sockets = Array(clientSockets)
        lock.unlock()
        // Workers own closing their descriptors, preventing a close/reuse race.
        for socket in sockets { _ = Darwin.shutdown(socket, SHUT_RDWR) }
        _ = Darwin.shutdown(listener, SHUT_RDWR)
    }

    private func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        defer { Darwin.close(listener) }
        while !isStopped() {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let socket = Darwin.accept(listener, nil, nil)
            guard socket >= 0 else { continue }
            var noSignal: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let index = acceptedCount
            acceptedCount += 1
            clientSockets.insert(socket)
            let mustStop = stopped
            lock.unlock()
            if mustStop { _ = Darwin.shutdown(socket, SHUT_RDWR) }
            let banner = banners[min(index, banners.count - 1)]
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(socket, banner: banner) }
        }
    }

    private func serve(_ socket: Int32, banner: Banner) {
        defer {
            lock.lock(); clientSockets.remove(socket); lock.unlock()
            Darwin.close(socket)
        }
        for (index, piece) in banner.pieces.enumerated() {
            if isStopped() { return }
            if index > 0 { Thread.sleep(forTimeInterval: 0.035) }
            let sent = piece.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
            if sent != piece.count { return }
        }
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 128)
        while !isStopped(), Date() < deadline {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 50) > 0 else { continue }
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { return }
            lock.lock(); incomingCount += count; lock.unlock()
        }
    }
}

@main
private struct NetworkDiscoveryTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("Network discovery test failed: \(message)") }
    }
    private static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        expect(condition(), "asynchronous operation completed within \(timeout) seconds")
    }
    private static func pump(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func expectThrows(_ message: String, _ action: () throws -> Void) {
        do {
            try action()
            fatalError("Network discovery test failed: \(message) did not throw")
        } catch { checks += 1 }
    }

    private static func plannerTests() throws {
        let local = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.42.7", netmask: "255.255.255.0")
        expect(local.interfaceName == "en0" && local.address == "192.168.42.7", "planner retains selected interface and address")
        expect(!local.displayName.isEmpty, "network offers a visible name")
        expect(local.prefixLength == 24 && local.scanPrefixLength == 24, "/24 has no scope expansion")
        expect(local.targetCount == 253, "/24 excludes self, network, and broadcast")
        expect(!local.isLimitedToLocalNeighborhood && local.isPrivateAddress, "private /24 flags")
        let wide = try VNCNetworkDiscovery.planNetwork(interfaceName: "en1", address: "10.33.44.55", netmask: "255.255.0.0")
        expect(wide.prefixLength == 16 && wide.scanPrefixLength == 24 && wide.targetCount == 255, "interior /24 neighborhood retains valid .0 and .255 hosts on a /16")
        expect(wide.isLimitedToLocalNeighborhood && wide.isPrivateAddress, "large private subnet explains its scope limit")
        let wideFirst = try VNCNetworkDiscovery.planNetwork(interfaceName: "en1", address: "10.33.0.55", netmask: "255.255.0.0")
        expect(wideFirst.targetCount == 254, "first /24 neighborhood on a /16 excludes the actual network endpoint only")
        let wideLast = try VNCNetworkDiscovery.planNetwork(interfaceName: "en1", address: "10.33.255.55", netmask: "255.255.0.0")
        expect(wideLast.targetCount == 254, "last /24 neighborhood on a /16 excludes the actual broadcast endpoint only")
        let lower23 = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.44.255", netmask: "255.255.254.0")
        expect(lower23.prefixLength == 23 && lower23.scanPrefixLength == 24 && lower23.targetCount == 254, "lower /23 half keeps its usable .255 host and excludes only the true network endpoint")
        let upper23 = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.45.0", netmask: "255.255.254.0")
        expect(upper23.prefixLength == 23 && upper23.scanPrefixLength == 24 && upper23.targetCount == 254, "upper /23 half keeps its usable .0 host and excludes only the true broadcast endpoint")
        let half = try VNCNetworkDiscovery.planNetwork(interfaceName: "en2", address: "172.16.1.130", netmask: "255.255.255.128")
        expect(half.prefixLength == 25 && half.scanPrefixLength == 25 && half.targetCount == 125, "/25 keeps actual subnet boundaries")
        let tiny = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.1.1", netmask: "255.255.255.252")
        expect(tiny.targetCount == 1, "/30 has one other usable host")
        let pointToPoint = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.1.0", netmask: "255.255.255.254")
        expect(pointToPoint.prefixLength == 31 && pointToPoint.targetCount == 1, "/31 retains the peer endpoint")
        let single = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.1.7", netmask: "255.255.255.255")
        expect(single.targetCount == 0, "/32 has no neighbors")
        expectThrows("unobserved public-address plans rejected") {
            _ = try VNCNetworkDiscovery.planNetwork(interfaceName: "en9", address: "198.51.100.7", netmask: "255.255.255.0")
        }
        expectThrows("malformed IPv4 address rejected") {
            _ = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "300.1.2.3", netmask: "255.255.255.0")
        }
        expectThrows("noncontiguous subnet mask rejected") {
            _ = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.1.7", netmask: "255.0.255.0")
        }
        expectThrows("malformed subnet mask rejected") {
            _ = try VNCNetworkDiscovery.planNetwork(interfaceName: "en0", address: "192.168.1.7", netmask: "not-a-mask")
        }
        expectThrows("VPN/tunnel interface rejected") {
            _ = try VNCNetworkDiscovery.planNetwork(interfaceName: "utun3", address: "10.0.0.7", netmask: "255.255.255.0")
        }
        expectThrows("test fixture cannot scan a LAN destination") {
            _ = try VNCNetworkDiscovery.testNetwork(targets: ["192.168.0.101"])
        }
        expectThrows("test fixture cannot scan a hostname") {
            _ = try VNCNetworkDiscovery.testNetwork(targets: ["localhost"])
        }
        print("PASS: subnet planning, private-network labels, /24 scope cap, /31-/32 edges, invalid input, and loopback-only fixture")
    }

    private static func bannerTest(_ banner: LoopbackVNCServer.Banner, expectedServer: Bool, name: String) throws {
        let server = try LoopbackVNCServer([banner])
        defer { server.stop() }
        let scanner = VNCNetworkDiscovery()
        defer { scanner.cancel() }
        let network = try VNCNetworkDiscovery.testNetwork(targets: ["127.0.0.1"])
        var updates: [VNCDiscoveryProgress] = []
        var result: [DiscoveredVNCServer]?
        let started = Date()
        try scanner.scan(network: network, port: server.port, onUpdate: { update in
            expect(Thread.isMainThread, "progress callback arrives on the main thread")
            expect(update.total == 1 && update.completed >= 0 && update.completed <= 1, "progress reports bounded completion")
            if let previous = updates.last { expect(update.completed >= previous.completed, "progress never goes backwards") }
            updates.append(update)
        }, onComplete: { servers in
            expect(Thread.isMainThread, "completion callback arrives on the main thread")
            expect(result == nil, "completion fires once")
            result = servers
        })
        pump(until: { result != nil })
        expect(result!.count == (expectedServer ? 1 : 0), "\(name) finds only a valid RFB banner")
        expect(updates.last?.completed == 1, "\(name) ends with completed progress")
        if let found = result!.first {
            expect(found.host == "127.0.0.1" && found.port == server.port, "discovery retains exact address and custom port")
            expect(found.protocolVersion == "003.008", "discovery preserves exact protocol version")
        }
        expect(Date().timeIntervalSince(started) < 4, "\(name) probe is bounded")
        pump(for: 0.05)
        expect(server.receivedBytes == 0, "discovery never writes authentication or input bytes")
        print("PASS: \(name)")
    }

    private static func cancellationTest() throws {
        let server = try LoopbackVNCServer([.silent, .valid])
        defer { server.stop() }
        let scanner = VNCNetworkDiscovery()
        defer { scanner.cancel() }
        let network = try VNCNetworkDiscovery.testNetwork(targets: ["127.0.0.1"])
        var cancelled = false
        var oldCallbacksAfterCancel = 0
        var oldCompletions = 0
        try scanner.scan(network: network, port: server.port, onUpdate: { _ in
            expect(Thread.isMainThread, "old-generation updates are delivered on the main thread")
            if cancelled { oldCallbacksAfterCancel += 1 }
        }, onComplete: { _ in
            oldCompletions += 1
            if cancelled { oldCallbacksAfterCancel += 1 }
        })
        pump(until: { server.acceptedConnections == 1 })
        cancelled = true
        let cancelledAt = Date()
        scanner.cancel()
        expect(Date().timeIntervalSince(cancelledAt) < 0.1, "Cancel returns without waiting for silent peers")
        var freshResult: [DiscoveredVNCServer]?
        try scanner.scan(network: network, port: server.port, onUpdate: { _ in
            expect(Thread.isMainThread, "new-generation update stays on main thread")
        }, onComplete: { freshResult = $0 })
        pump(until: { freshResult != nil })
        expect(freshResult?.count == 1, "a new scan can complete immediately after cancellation")
        pump(until: { server.activeConnections == 0 }, timeout: 0.65)
        expect(server.activeConnections == 0, "cancel/rescan closes both the silent and completed TCP connections")
        pump(for: 1.6)
        expect(oldCallbacksAfterCancel == 0 && oldCompletions == 0, "cancelled scan never delivers stale progress or completion")
        expect(server.receivedBytes == 0, "cancel/rescan does not write VNC authentication")
        expectThrows("zero destination port rejected") {
            try scanner.scan(network: network, port: 0, onUpdate: { _ in }, onComplete: { _ in })
        }
        print("PASS: nonblocking cancellation, immediate rescan, and stale-callback suppression")
    }

    static func main() throws {
        expect(Thread.isMainThread, "test harness owns the main run loop")
        try plannerTests()
        try bannerTest(.valid, expectedServer: true, name: "valid RFB banner on a custom port")
        try bannerTest(.partial, expectedServer: true, name: "RFB banner split across TCP reads")
        try bannerTest(.malformed, expectedServer: false, name: "non-VNC service rejected")
        try bannerTest(.silent, expectedServer: false, name: "silent service times out")
        try cancellationTest()
        print("PASS: \(checks) network discovery checks; only owned IPv4 loopback sockets were contacted")
    }
}
