// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A passive transport estimate, never an input-to-screen measurement. macOS
/// exposes no timestamp for the RTT sample; activity age refers only to observed
/// changes in transport counters, not to when the kernel measured its RTT.
struct NetworkLatency: Equatable {
    let milliseconds: Double?
    let observedActivityAgeMilliseconds: Double?
    let isIdle: Bool

    static let unavailable=NetworkLatency(milliseconds:nil)

    init(milliseconds: Double?, observedActivityAgeMilliseconds: Double?=nil, isIdle: Bool=false) {
        let valid=milliseconds.flatMap { $0.isFinite && $0 >= 1 && $0 <= Double(UInt32.max) ? $0 : nil }
        self.milliseconds=valid
        self.observedActivityAgeMilliseconds=valid == nil ? nil : observedActivityAgeMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.isIdle=valid != nil && isIdle
    }

    var title: String {
        guard let milliseconds=milliseconds else { return "RTT unavailable" }
        let value=milliseconds > 9999 ? ">9999" : String(Int(milliseconds.rounded()))
        return "RTT \(value) ms" + (isIdle ? " · idle" : "")
    }

    var toolTip: String {
        var text="Smoothed TCP round-trip estimate from macOS for this VNC connection. This is not input-to-screen delay: screen capture, encoding, transfer, decoding and rendering can add delay. The estimate may stay unchanged while idle. With port forwarding, it can measure the forwarding endpoint. No extra ping packets are sent."
        if milliseconds == nil { text += " No usable estimate is available yet." }
        if isIdle,let age=observedActivityAgeMilliseconds {
            let seconds=min(age/1000,Double(Int.max/2))
            text += " Last traffic-counter change observed \(Int(seconds.rounded(.down))) s ago; this is not the RTT sample age."
        }
        return text
    }
}
