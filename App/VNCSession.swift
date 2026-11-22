// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

final class VNCSession {
    var onConnected: ((String, Int, Int) -> Void)?
    var onFrame: ((UnsafePointer<UInt8>, Int, Int, Int, FrameRegion) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onDisconnected: ((String, Bool) -> Void)?
    private var client: OpaquePointer?
    private var keepAlive: VNCSession?
    private var closing = false

    func start(host: String, port: UInt16, password: String, viewOnly: Bool, quality: Int32, compression: Int32 = 1) -> Bool {
        var callbacks = vncv_callbacks()
        callbacks.connected = { context, name, width, height in
            guard let context = context else { return }
            let session = Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue()
            let title = name.map { String(cString: $0) } ?? "Remote desktop"
            DispatchQueue.main.async { session.onConnected?(title, Int(width), Int(height)) }
        }
        callbacks.frame = { context, bytes, width, height, stride, x, y, changedWidth, changedHeight in
            guard let context = context, let bytes = bytes else { return }
            let session = Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue()
            session.onFrame?(bytes, Int(width), Int(height), Int(stride),
                             FrameRegion(x:Int(x),y:Int(y),width:Int(changedWidth),height:Int(changedHeight)))
        }
        callbacks.clipboard = { context, text, length in
            guard let context = context, let text = text else { return }
            let session = Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue()
            let value = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: length), as: UTF8.self)
            DispatchQueue.main.async { session.onClipboard?(value) }
        }
        callbacks.disconnected = { context, message, intentional in
            guard let context = context else { return }
            let session = Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue()
            let reason = message.map { String(cString: $0) } ?? "Connection closed."
            DispatchQueue.main.async {
                session.onDisconnected?(reason, intentional != 0)
                session.dispose()
            }
        }
        guard let handle = vncv_create(callbacks, Unmanaged.passUnretained(self).toOpaque()) else { return false }
        client = handle
        keepAlive = self
        let started = host.withCString { hostBytes in password.withCString { passwordBytes in
            vncv_start_with_options(handle, hostBytes, port, passwordBytes, viewOnly ? 1 : 0, quality, compression) != 0
        }}
        if !started { dispose() }
        return started
    }

    func stop() { if let client = client { vncv_stop(client) } }
    func networkLatency() -> NetworkLatency {
        guard let client=client else { return .unavailable }
        var snapshot=vncv_network_rtt()
        guard vncv_get_network_rtt(client,&snapshot) != 0,snapshot.available != 0 else { return .unavailable }
        return NetworkLatency(milliseconds:snapshot.rtt_ms,
                              observedActivityAgeMilliseconds:snapshot.observed_activity_age_ms,
                              isIdle:snapshot.stale != 0)
    }
    func key(_ symbol: UInt32, down: Bool) { if let client = client { _ = vncv_key(client, symbol, down ? 1 : 0) } }
    func pointer(x: Int32, y: Int32, mask: Int32) { if let client = client { _ = vncv_pointer(client, x, y, mask) } }
    func refresh() { if let client = client { _ = vncv_refresh(client) } }
    func viewOnly(_ value: Bool) { if let client = client { _ = vncv_set_view_only(client, value ? 1 : 0) } }
    @discardableResult
    func setUpdateInterval(milliseconds: UInt32) -> Bool {
        guard let client = client else { return false }
        return vncv_set_update_interval(client, milliseconds) != 0
    }
    func clipboard(_ value: String) {
        guard let client = client else { return }
        value.utf8CString.withUnsafeBufferPointer { data in
            _ = vncv_clipboard(client, data.baseAddress, max(0, data.count-1))
        }
    }
    func controlAltDelete() {
        key(0xffe3, down: true); key(0xffe9, down: true); key(0xffff, down: true)
        key(0xffff, down: false); key(0xffe9, down: false); key(0xffe3, down: false)
    }
    private func dispose() {
        guard !closing, let handle = client else { return }
        closing = true; client = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            vncv_destroy(handle)
            DispatchQueue.main.async { self.keepAlive = nil }
        }
    }
}
