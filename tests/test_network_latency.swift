// SPDX-License-Identifier: GPL-2.0-or-later
// Pure formatter/meaning checks. No sockets, timers, preferences, or UI.
import Foundation

@main
struct NetworkLatencyTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError("Network latency test: \(label)") }
    }

    static func main() {
        let unavailable = NetworkLatency.unavailable
        expect(unavailable.title == "RTT —", "missing estimate uses a dash rather than zero milliseconds")
        expect(unavailable.milliseconds == nil && !unavailable.isIdle && unavailable.observedActivityAgeMilliseconds == nil,
               "unavailable state carries no stale metadata")
        for value: Double? in [nil, 0, -1, 0.999, .nan, .infinity, -.infinity, Double(UInt32.max) + 1, Double.greatestFiniteMagnitude] {
            let result = NetworkLatency(milliseconds: value, observedActivityAgeMilliseconds: 15000, isIdle: true)
            expect(result == unavailable, "invalid transport estimate normalizes to unavailable")
            expect(result.title == "RTT —", "invalid estimate never becomes a plausible numeric latency")
            expect(result.toolTip.contains("No usable estimate"), "unavailable tooltip explains absent measurement")
        }
        let cases: [(Double, String)] = [(1,"RTT 1 ms"), (12,"RTT 12 ms"), (250,"RTT 250 ms"),
            (999,"RTT 999 ms"), (9999,"RTT 9999 ms"), (10000,"RTT >9999 ms"),
            (Double(UInt32.max),"RTT >9999 ms")]
        for (value, title) in cases {
            let result = NetworkLatency(milliseconds: value)
            expect(result.milliseconds == value, "valid estimate retains its value")
            expect(result.title == title, "compact formatting preserves units and bounds")
            expect(!result.toolTip.contains("No usable estimate"), "available estimate does not claim unavailable")
        }
        expect(NetworkLatency(milliseconds: 1.49).title == "RTT 1 ms", "fractional valid estimate rounds to the nearest integer")
        expect(NetworkLatency(milliseconds: 1.5).title == "RTT 2 ms", "half-millisecond estimate rounds consistently")
        expect(NetworkLatency(milliseconds: 9999.1).title == "RTT >9999 ms", "above-bound fractional estimate stays honestly bounded")
        let explanation = NetworkLatency(milliseconds: 12).toolTip
        for phrase in ["Smoothed TCP", "not input-to-screen delay", "screen capture", "encoding", "decoding", "rendering",
                       "unchanged while idle", "forwarding endpoint", "No extra ping packets"] {
            expect(explanation.contains(phrase), "tooltip explains transport measurement scope: \(phrase)")
        }
        let idle = NetworkLatency(milliseconds: 12, observedActivityAgeMilliseconds: 15999, isIdle: true)
        expect(idle.title == "RTT 12 ms · idle", "idle estimate remains visible with an explicit qualifier")
        expect(idle.toolTip.contains("15 s ago"), "observed traffic age uses whole seconds")
        expect(idle.toolTip.contains("not the RTT sample age"), "observed activity is not presented as a fresh RTT timestamp")
        expect(NetworkLatency(milliseconds: 12, observedActivityAgeMilliseconds: 15000).title == "RTT 12 ms",
               "activity age alone does not fabricate idle state")
        expect(!NetworkLatency(milliseconds: 12, observedActivityAgeMilliseconds: 15000).toolTip.contains("s ago"),
               "nonidle state does not expose an irrelevant cached activity age")
        for age in [-1.0, Double.nan, .infinity, -.infinity] {
            let result = NetworkLatency(milliseconds: 12, observedActivityAgeMilliseconds: age, isIdle: true)
            expect(result.observedActivityAgeMilliseconds == nil, "invalid observed activity age is discarded")
            expect(result.title == "RTT 12 ms · idle" && !result.toolTip.contains("s ago"),
                   "invalid activity age never causes a fabricated timestamp")
        }
        let large = NetworkLatency(milliseconds: Double(UInt32.max), observedActivityAgeMilliseconds: .greatestFiniteMagnitude, isIdle: true)
        expect(large.title == "RTT >9999 ms · idle" && large.title.count < 24, "worst-case idle title has bounded width")
        expect(!large.toolTip.lowercased().contains("inf") && !large.toolTip.lowercased().contains("nan"),
               "huge finite activity age formats safely without numeric traps")
        expect(NetworkLatency(milliseconds: 12, observedActivityAgeMilliseconds: 0, isIdle: true).toolTip.contains("0 s ago"),
               "zero observed activity age remains valid metadata")
        print("PASS: \(checks) pure network-latency formatting, bounds, and measurement-scope checks")
    }
}
