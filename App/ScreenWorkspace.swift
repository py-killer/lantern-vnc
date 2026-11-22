// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Selection and incoming callbacks use the same gate. A callback from an old
/// endpoint can never paint over the newly selected desktop, even during resize
/// or when a closing connection delivers one last frame.
final class ScreenFrameRouter {
    private let lock = NSLock()
    private var selected: UUID?
    private let receiveFrame: (UnsafePointer<UInt8>, Int, Int, Int, FrameRegion) -> Void

    init(receive: @escaping (UnsafePointer<UInt8>, Int, Int, Int, FrameRegion) -> Void) {
        receiveFrame = receive
    }

    func select(_ token: UUID?, reset: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        selected = token
        reset()
    }

    @discardableResult
    func receive(token: UUID, bytes: UnsafePointer<UInt8>, width: Int, height: Int,
                 stride: Int, dirty: FrameRegion) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard selected == token else { return false }
        receiveFrame(bytes, width, height, stride, dirty)
        return true
    }
}

/// One native session per endpoint, with only a small thumbnail in addition to
/// the native framebuffer. The selected endpoint alone feeds MetalDesktop.
final class WorkspaceComputer {
    enum Phase: Equatable {
        case connecting
        case connected
        case closing
    }
    let key: String
    let host: String
    let port: UInt16
    let token = UUID()
    let session = VNCSession()
    let sampler: ScreenPreviewSampler
    var phase: Phase = .connecting
    var name: String
    var size = NSSize.zero
    var preview: NSImage?
    var sampledAt: TimeInterval?
    var credentialNote: String?
    // Metadata only: pending user opt-in or an already confirmed saved read.
    // No authenticated plaintext is retained for later checkbox changes.
    var remembersPassword: Bool

    init(host: String, port: UInt16, name: String, previewInterval: TimeInterval = 10, remembersPassword: Bool = false) {
        self.host = host; self.port = port; self.name = name
        self.remembersPassword=remembersPassword
        sampler=ScreenPreviewSampler(minimumInterval:previewInterval)
        key = Self.key(host: host, port: port)
    }

    static func key(host: String, port: UInt16) -> String {
        "\(host.lowercased().utf8.count):\(host.lowercased()):\(port)"
    }
}
