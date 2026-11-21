// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct FrameUpdateTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("Frame update test failed: \(message)") }
    }
    struct Random {
        var seed: UInt64 = 0x63a0b6e7d9801f25
        mutating func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 16) % UInt64(limit))
        }
    }
    struct Slot {
        var pixels: [UInt8] = []
        var state: FrameUpdateState?
    }
    static func image(_ width: Int, _ height: Int, stride: Int, seed: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0xed, count: stride * height)
        for y in 0..<height { for x in 0..<width { for channel in 0..<4 {
            result[y * stride + x * 4 + channel] = UInt8(truncatingIfNeeded: seed + x * 17 + y * 31 + channel * 67)
        } } }
        return result
    }
    static func clip(_ region: FrameRegion, width: Int, height: Int) -> FrameRegion {
        FrameRegion(x:region.x,y:region.y,width:min(region.width,width-region.x),height:min(region.height,height-region.y))
    }
    static func changeOracle(_ oracle: inout [UInt8], source: [UInt8], stride: Int, width: Int, region: FrameRegion) {
        for y in region.y..<(region.y + region.height) {
            let start = (y * width + region.x) * 4, count = region.width * 4
            oracle.replaceSubrange(start..<(start+count),with:source[(y*stride+region.x*4)..<(y*stride+region.x*4+count)])
        }
    }
    @discardableResult
    static func receive(_ store: FrameUpdateStore, _ source: [UInt8], width: Int, height: Int, stride: Int, dirty: FrameRegion? = nil) -> Bool {
        source.withUnsafeBufferPointer { store.receive($0.baseAddress!,width:width,height:height,stride:stride,dirty:dirty) }
    }
    static func directSnapshot(_ store:FrameUpdateStore,slot:Int,generation:UInt64) -> FrameUpload? {
        var result:FrameUpload?
        let committed=store.withUpdate(slot:slot,expectedGeneration:generation) { pointer,rowStride,region,state in
            expect(rowStride == state.width*4,"direct oracle uses canonical row stride")
            var packed=Data()
            for row in 0..<region.height {
                packed.append(pointer.advanced(by:row*rowStride).assumingMemoryBound(to:UInt8.self),count:region.width*4)
            }
            result=FrameUpload(data:packed,region:region,state:state)
            return true
        }
        expect(committed == (result != nil),"direct oracle callback and commit agree")
        return result
    }
    static func apply(_ upload: FrameUpload, to slot: inout Slot, expected: [UInt8], _ label: String) {
        let r = upload.region, state = upload.state
        expect(r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0,"\(label): positive patch")
        expect(r.x + r.width <= state.width && r.y + r.height <= state.height,"\(label): patch in bounds")
        expect(upload.bytesPerRow == r.width * 4 && upload.data.count == r.byteCount,"\(label): tightly packed rows")
        if slot.state?.generation != state.generation || slot.state?.width != state.width || slot.state?.height != state.height {
            expect(r == FrameRegion(x:0,y:0,width:state.width,height:state.height),"\(label): new texture requires whole image")
            slot.pixels = [UInt8](repeating:0,count:state.width * state.height * 4)
        }
        for row in 0..<r.height {
            let destination = ((r.y + row) * state.width + r.x) * 4, source = row * upload.bytesPerRow
            slot.pixels.replaceSubrange(destination..<(destination+upload.bytesPerRow),with:upload.data[source..<(source+upload.bytesPerRow)])
        }
        slot.state = state
        expect(slot.pixels == expected,"\(label): reconstructed BGRX image matches independent oracle")
    }
    static func validation() {
        let store = FrameUpdateStore()
        expect(store.state == nil && store.framesReceived == 0,"empty state")
        expect(!store.hasPending(slot:0) && store.takeUpdate(slot:0) == nil,"empty upload")
        let bytes = [UInt8](repeating:0,count:64)
        for region in [FrameRegion(x:-1,y:0,width:1,height:1),FrameRegion(x:0,y:0,width:0,height:1),
                       FrameRegion(x:0,y:0,width:1,height:-1),FrameRegion(x:4,y:0,width:1,height:1)] {
            expect(!receive(store,bytes,width:4,height:4,stride:16,dirty:region),"reject invalid first dirty rectangle")
            expect(store.state == nil && store.framesReceived == 0,"invalid first update does not reset state")
        }
        expect(!receive(store,bytes,width:0,height:4,stride:16),"reject zero width")
        expect(!receive(store,bytes,width:4,height:0,stride:16),"reject zero height")
        expect(!receive(store,bytes,width:4,height:4,stride:15),"reject short stride")
        expect(!receive(store,bytes,width:16385,height:1,stride:65540),"reject excessive axis before reading pointer")
        expect(!receive(store,bytes,width:16384,height:16384,stride:65536),"reject excessive bytes before allocation/read")
        expect(!receive(store,bytes,width:1,height:2,stride:Int.max),"reject stride multiplication overflow")

        let width=7,height=5,stride=width*4+12,source=image(width,height,stride:stride,seed:9)
        var oracle=[UInt8](repeating:0,count:width*height*4)
        let full=FrameRegion(x:0,y:0,width:width,height:height)
        changeOracle(&oracle,source:source,stride:stride,width:width,region:full)
        expect(receive(store,source,width:width,height:height,stride:stride,dirty:FrameRegion(x:2,y:2,width:1,height:1)),"first valid update accepts padded rows")
        expect(store.statistics.copiedBytes == full.byteCount,"first update ingests complete image")
        let generation=store.state!.generation
        expect(store.takeUpdate(slot:0,expectedGeneration:generation &+ 1) == nil,"generation mismatch rejects plan")
        expect(store.hasPending(slot:0),"generation mismatch preserves pending pixels")
        var slots=[Slot(),Slot(),Slot()]
        for index in slots.indices {
            guard let upload=store.takeUpdate(slot:index,expectedGeneration:generation) else { fatalError("missing initial patch") }
            apply(upload,to:&slots[index],expected:oracle,"initial slot \(index)")
            expect(!store.hasPending(slot:index) && store.takeUpdate(slot:index) == nil,"only one pending initial upload per slot")
        }
        expect(store.statistics.snapshotBytes == full.byteCount*3 && store.statistics.fullSnapshots == 3,"full initial snapshots counted")
        let newSource=image(width,height,stride:stride,seed:123)
        let dirty=FrameRegion(x:width-2,y:height-1,width:10,height:4),clipped=clip(dirty,width:width,height:height)
        let before=store.statistics
        expect(receive(store,newSource,width:width,height:height,stride:stride,dirty:dirty),"clip positively overlapping rectangle")
        changeOracle(&oracle,source:newSource,stride:stride,width:width,region:clipped)
        let first=store.takeUpdate(slot:0)!
        expect(first.region == clipped,"edge clip excludes offscreen area")
        apply(first,to:&slots[0],expected:oracle,"clipped last-pixel patch")
        expect(store.statistics.copiedBytes-before.copiedBytes == clipped.byteCount,"only declared dirty rows ingested")
        expect(store.statistics.snapshotBytes-before.snapshotBytes == clipped.byteCount,"only clipped patch snapshotted")
        expect(store.statistics.partialSnapshots == 1,"partial snapshot counted")
        store.invalidate(slot:0)
        expect(store.takeUpdate(slot:0)!.region == full,"invalidated slot receives complete canonical frame")
        let preservedState=store.state!,preservedFrames=store.framesReceived,preservedStats=store.statistics
        expect(!receive(store,newSource,width:width,height:height,stride:stride,dirty:FrameRegion(x:width,y:0,width:1,height:1)),"reject wholly outside rectangle")
        expect(store.state == preservedState && store.framesReceived == preservedFrames,"invalid update preserves latest state/count")
        expect(store.statistics.copiedBytes == preservedStats.copiedBytes,"invalid update copies no bytes")
        store.clear()
        expect(store.state == nil && store.framesReceived == 0,"clear removes state/count")
        expect(store.statistics.updates == 0 && store.statistics.copiedBytes == 0 && store.statistics.snapshotBytes == 0,"clear resets statistics")
        expect(!store.hasPending(slot:0),"clear removes pending slots")
        expect(receive(store,source,width:width,height:height,stride:stride),"receive after clear")
        expect(store.state!.generation != generation,"clear invalidates old generation")
        expect(store.takeUpdate(slot:0,expectedGeneration:generation) == nil && store.hasPending(slot:0),"pre-clear generation cannot consume new pixels")
        let beforeResize=store.state!.generation,newWidth=9,newHeight=3,newStride=40
        let resizedSource=image(newWidth,newHeight,stride:newStride,seed:177)
        var resizedOracle=[UInt8](repeating:0,count:newWidth*newHeight*4)
        changeOracle(&resizedOracle,source:resizedSource,stride:newStride,width:newWidth,region:FrameRegion(x:0,y:0,width:newWidth,height:newHeight))
        expect(receive(store,resizedSource,width:newWidth,height:newHeight,stride:newStride,dirty:FrameRegion(x:4,y:1,width:1,height:1)),"resize with partial callback accepted")
        expect(store.state!.generation != beforeResize,"resize advances generation")
        var resizedSlot=Slot()
        apply(store.takeUpdate(slot:0)!,to:&resizedSlot,expected:resizedOracle,"resize partial callback initializes whole new image")
    }
    static func randomizedOracle() {
        let store=FrameUpdateStore()
        var rng=Random(),slots=[Slot(),Slot(),Slot()],width=29,height=17,oracle=[UInt8]()
        var held: (FrameUpload,[UInt8])?
        for step in 0..<450 {
            let resize = step == 0 || step % 53 == 0
            if resize { width=13+rng.next(38);height=11+rng.next(31);oracle=[UInt8](repeating:0,count:width*height*4) }
            let stride=width*4+(step%4)*4,source=image(width,height,stride:stride,seed:step*43)
            let region=resize ? FrameRegion(x:0,y:0,width:width,height:height) :
                FrameRegion(x:rng.next(width),y:rng.next(height),width:1+rng.next(width),height:1+rng.next(height))
            let accepted=clip(region,width:width,height:height)
            changeOracle(&oracle,source:source,stride:stride,width:width,region:accepted)
            let previous=store.state
            expect(receive(store,source,width:width,height:height,stride:stride,dirty:region),"random receive \(step)")
            let state=store.state!
            expect(state.width == width && state.height == height,"random dimensions")
            if let previous=previous { expect(state.sequence > previous.sequence,"sequence increases across receive/resize") }
            if let held=held { expect(Array(held.0.data) == held.1,"detached upload remains immutable after new frames/resizes") }
            if step % 19 == 0 { store.invalidate(slot:step%3) }
            // Slot 2 is deliberately neglected: independently coalesced unions
            // must preserve old dirty areas without an unbounded history list.
            let selected = step % 41 == 0 ? [0,1,2] : step % 3 == 0 ? [0] : step % 7 == 0 ? [1] : []
            for index in selected {
                let pending=step % 2 == 0 ? directSnapshot(store,slot:index,generation:state.generation) :
                    store.takeUpdate(slot:index,expectedGeneration:state.generation)
                if let upload=pending {
                    expect(upload.state == state,"upload corresponds to atomic latest state")
                    apply(upload,to:&slots[index],expected:oracle,"random step \(step) slot \(index)")
                    held=(upload,Array(upload.data))
                }
            }
        }
        for index in slots.indices {
            if let upload=store.takeUpdate(slot:index) { apply(upload,to:&slots[index],expected:oracle,"final slot \(index)") }
            expect(slots[index].pixels == oracle,"all slots converge after long stale intervals")
        }
        expect(store.framesReceived == 450 && store.statistics.updates == 450,"accepted update accounting")
    }
    static func directUploads() {
        let store=FrameUpdateStore(),width=23,height=19,stride=100
        var source=image(width,height,stride:stride,seed:7),oracle=[UInt8](repeating:0,count:width*height*4),slots=[Slot(),Slot(),Slot()]
        changeOracle(&oracle,source:source,stride:stride,width:width,region:FrameRegion(x:0,y:0,width:width,height:height))
        expect(receive(store,source,width:width,height:height,stride:stride),"direct initial receive")
        func upload(_ index:Int) {
            var detached:FrameUpload?
            let accepted=store.withUpdate(slot:index) { pointer,rowStride,region,state in
                expect(rowStride == state.width*4,"direct callback uses canonical full-row stride")
                var packed=Data()
                for row in 0..<region.height {
                    packed.append(pointer.advanced(by:row*rowStride).assumingMemoryBound(to:UInt8.self),count:region.width*4)
                }
                detached=FrameUpload(data:packed,region:region,state:state)
                return true
            }
            expect(accepted && detached != nil,"direct upload committed")
            apply(detached!,to:&slots[index],expected:oracle,"direct slot \(index)")
        }
        for index in 0..<3 { upload(index) }
        let fullBytes=width*height*4
        expect(store.statistics.snapshotBytes == 0,"direct upload creates no packed snapshots")
        expect(store.statistics.directUploadBytes == 3*fullBytes,"direct initial byte accounting")
        let first=FrameRegion(x:3,y:2,width:4,height:5)
        source=image(width,height,stride:stride,seed:51)
        expect(receive(store,source,width:width,height:height,stride:stride,dirty:first),"first direct patch")
        changeOracle(&oracle,source:source,stride:stride,width:width,region:first)
        let before=store.statistics.directUploadBytes
        var invoked=false
        expect(!store.withUpdate(slot:0,expectedGeneration:store.state!.generation &+ 1) { _,_,_,_ in invoked=true;return true },"direct generation mismatch")
        expect(!invoked && store.hasPending(slot:0),"generation rejection preserves pending union")
        expect(!store.withUpdate(slot:-1) { _,_,_,_ in invoked=true;return true },"direct invalid slot rejected")
        expect(!invoked,"invalid slot never calls closure")
        expect(!store.withUpdate(slot:0) { pointer,rowStride,region,_ in
            expect(region == first && rowStride == width*4,"direct partial origin and canonical stride")
            expect(pointer.load(as:UInt8.self) == oracle[(first.y*width+first.x)*4],"pointer already starts at region origin")
            return false
        },"failed direct upload does not commit")
        expect(store.hasPending(slot:0) && store.statistics.directUploadBytes == before,"failed direct upload preserves damage and byte accounting")
        let second=FrameRegion(x:12,y:10,width:2,height:3)
        source=image(width,height,stride:stride,seed:99)
        expect(receive(store,source,width:width,height:height,stride:stride,dirty:second),"second direct patch after failed upload")
        changeOracle(&oracle,source:source,stride:stride,width:width,region:second)
        for index in 0..<3 { upload(index);expect(!store.hasPending(slot:index),"direct clears only committed slot") }
        expect(store.statistics.snapshotBytes == 0 && store.statistics.partialSnapshots == 0,"production direct path never packs snapshots")
        store.invalidate(slot:1);upload(1)
        expect(!store.hasPending(slot:0) && !store.hasPending(slot:2),"invalidating one slot leaves other slots untouched")
    }
    static func concurrentSnapshots() {
        final class Completion {
            let lock=NSLock()
            var value=false
            func finish() { lock.lock();value=true;lock.unlock() }
            func finished() -> Bool { lock.lock();defer { lock.unlock() };return value }
        }
        let store=FrameUpdateStore(),completion=Completion(),group=DispatchGroup(),start=DispatchSemaphore(value:0)
        let width=17,height=11,stride=68,count=600
        group.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer { group.leave() }
            start.wait()
            for sequence in 1...count {
                let source=image(width,height,stride:stride,seed:sequence*29)
                if !receive(store,source,width:width,height:height,stride:stride) { fatalError("concurrent receive rejected") }
                if sequence % 20 == 0 { Thread.sleep(forTimeInterval:0.0001) }
            }
            completion.finish()
        }
        group.enter()
        DispatchQueue.global(qos:.userInitiated).async {
            defer { group.leave() }
            start.signal()
            var index=0
            repeat {
                if index % 2 == 0 {
                    _ = store.withUpdate(slot:index) { pointer,rowStride,region,state in
                        let expected=image(width,height,stride:stride,seed:state.sequence*29)
                        expect(region == FrameRegion(x:0,y:0,width:width,height:height) && rowStride == stride,"concurrent direct frame shape")
                        expect(Array(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:UInt8.self),count:expected.count)) == expected,"concurrent direct pointer matches declared sequence")
                        return true
                    }
                } else if let upload=store.takeUpdate(slot:index) {
                    let expected=image(width,height,stride:stride,seed:upload.state.sequence*29)
                    expect(Array(upload.data) == expected,"concurrent snapshot is one complete declared sequence")
                    let detached=Array(upload.data)
                    Thread.sleep(forTimeInterval:0.00002)
                    expect(Array(upload.data) == detached,"concurrent later receive cannot mutate detached payload")
                }
                index=(index+1)%3
            } while !completion.finished() || (0..<3).contains(where:{store.hasPending(slot:$0)})
        }
        let completed=group.wait(timeout:.now()+10)
        expect(completed == .success,"concurrent producer/consumer completes without deadlock")
        expect(store.framesReceived == count && store.state?.sequence == count,"concurrent update accounting")
    }
    static func benchmark() -> [[String:Any]] {
        let width=5120,height=2880,stride=width*4,fullBytes=stride*height
        let instrumented=ProcessInfo.processInfo.environment["FRAME_TEST_SANITIZE"] == "1"
        let iterations=instrumented ? 4 : 24
        var reports=[[String:Any]](),source=[UInt8](repeating:0x5a,count:fullBytes)
        for (name,region) in [("full",FrameRegion(x:0,y:0,width:width,height:height)),
                              ("32x32",FrameRegion(x:311,y:197,width:32,height:32)),
                              ("256x64",FrameRegion(x:257,y:131,width:256,height:64))] {
            let offset=region.y*stride+region.x*4
            var checksum:UInt64=0
            let baselineStart=DispatchTime.now().uptimeNanoseconds
            source.withUnsafeMutableBufferPointer { buffer in
                for _ in 0..<iterations {
                    buffer[offset] &+= 1
                    let snapshot=Data(bytes:buffer.baseAddress!,count:fullBytes)
                    checksum &+= UInt64(snapshot[offset])
                }
            }
            let baselineNS=DispatchTime.now().uptimeNanoseconds-baselineStart
            let store=FrameUpdateStore()
            expect(receive(store,source,width:width,height:height,stride:stride),"benchmark initial receive")
            for slot in 0..<3 { expect(store.withUpdate(slot:slot) { _,_,_,_ in true },"warm initial direct slot") }
            let before=store.statistics
            let start=DispatchTime.now().uptimeNanoseconds
            source.withUnsafeMutableBufferPointer { buffer in
                for step in 0..<iterations {
                    buffer[offset] &+= 1
                    expect(store.receive(buffer.baseAddress!,width:width,height:height,stride:stride,dirty:region),"benchmark receive")
                    expect(store.withUpdate(slot:step%3) { pointer,_,_,_ in
                        checksum &+= UInt64(pointer.load(as:UInt8.self));return true
                    },"benchmark direct callback")
                }
            }
            let elapsed=DispatchTime.now().uptimeNanoseconds-start,after=store.statistics
            let copied=after.copiedBytes-before.copiedBytes,snapshots=after.snapshotBytes-before.snapshotBytes
            expect(copied == region.byteCount*iterations,"benchmark exact ingestion bytes \(name)")
            expect(snapshots == 0,"benchmark direct path makes no packed snapshots \(name)")
            let directBytes=after.directUploadBytes-before.directUploadBytes
            expect(directBytes == region.byteCount*iterations,"benchmark exact direct region bytes \(name)")
            let fallback=FrameUpdateStore()
            expect(receive(fallback,source,width:width,height:height,stride:stride),"fallback benchmark initialization")
            for slot in 0..<3 { _=fallback.takeUpdate(slot:slot) }
            let fallbackBefore=fallback.statistics,fallbackStart=DispatchTime.now().uptimeNanoseconds
            source.withUnsafeMutableBufferPointer { buffer in
                for step in 0..<iterations {
                    buffer[offset] &+= 1
                    expect(fallback.receive(buffer.baseAddress!,width:width,height:height,stride:stride,dirty:region),"fallback benchmark receive")
                    guard let upload=fallback.takeUpdate(slot:step%3) else { fatalError("missing fallback snapshot") }
                    checksum &+= UInt64(upload.data[0])
                }
            }
            let fallbackNS=DispatchTime.now().uptimeNanoseconds-fallbackStart,fallbackAfter=fallback.statistics
            expect(fallbackAfter.snapshotBytes-fallbackBefore.snapshotBytes == region.byteCount*iterations,"fallback exact snapshot bytes")
            reports.append(["workload":name,"width":width,"height":height,"iterations":iterations,
                "baselineFullSnapshotBytes":fullBytes*iterations,"baselineFullSnapshotNanoseconds":baselineNS,
                "dirtyIngestionBytes":copied,"packedSnapshotBytes":snapshots,"directCallbackRegionBytes":directBytes,"dirtyIngestionAndDirectCallbackNanoseconds":elapsed,
                "fallbackIngestionBytes":fallbackAfter.copiedBytes-fallbackBefore.copiedBytes,"fallbackPackedSnapshotBytes":fallbackAfter.snapshotBytes-fallbackBefore.snapshotBytes,"fallbackIngestionAndSnapshotNanoseconds":fallbackNS,
                "fullSnapshots":after.fullSnapshots-before.fullSnapshots,"partialSnapshots":after.partialSnapshots-before.partialSnapshots,
                "checksum":checksum,"initialFullFrameAndThreeSlotWarmupExcluded":true])
        }
        return reports
    }
    static func main() throws {
        validation();randomizedOracle();directUploads();concurrentSnapshots()
        let measurements=benchmark()
        let report:[String:Any]=["checks":checks,"passed":true,"randomizedUpdates":450,"concurrentUpdates":600,
            "instrumentedWithAddressSanitizer":ProcessInfo.processInfo.environment["FRAME_TEST_SANITIZE"] == "1",
            "scope":"Local CPU copies only. Baseline is one full Data copy; production measurement ingests canonical dirty rows and samples a synchronous borrowed pointer without packing. Direct callback region bytes are eligible upload bytes, not measured GPU traffic. Immutable packed fallback measured separately. No GPU/network/JPEG throughput or latency claim. Fixed-region steady-state workloads; initialization excluded.",
            "benchmarks":measurements]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic) }
        print("PASS: \(checks) frame-update checks; 450 seeded updates with three independently stale texture slots")
        print(String(decoding:data,as:UTF8.self))
    }
}
