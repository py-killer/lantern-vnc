// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct FrameRegion: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    var byteCount: Int { width * height * 4 }

    fileprivate func clipped(width limitWidth: Int, height limitHeight: Int) -> FrameRegion? {
        guard x >= 0, y >= 0, width > 0, height > 0, x < limitWidth, y < limitHeight else { return nil }
        return FrameRegion(x:x,y:y,width:min(width,limitWidth-x),height:min(height,limitHeight-y))
    }
    fileprivate func union(_ other: FrameRegion) -> FrameRegion {
        let left=min(x,other.x), top=min(y,other.y)
        return FrameRegion(x:left,y:top,width:max(x+width,other.x+other.width)-left,
                           height:max(y+height,other.y+other.height)-top)
    }
}

struct FrameUpdateState: Equatable {
    let width: Int
    let height: Int
    let sequence: Int
    let generation: UInt64
}

struct FrameUpload {
    let data: Data
    let region: FrameRegion
    let state: FrameUpdateState
    var bytesPerRow: Int { region.width * 4 }
}

struct FrameUpdateStatistics {
    var updates=0
    var copiedBytes=0
    var snapshotBytes=0
    var fullSnapshots=0
    var partialSnapshots=0
    var directUploadBytes=0
}

/// A single owned CPU image with independent accumulated damage for each GPU
/// texture. No native pointer escapes receive(), and upload payloads never alias
/// the mutable image. Three unions bound bookkeeping even if rendering stalls.
final class FrameUpdateStore {
    private let lock=NSLock()
    private var pixels=Data()
    private var current: FrameUpdateState?
    private var generation: UInt64=0
    private var damage: [FrameRegion?]
    private var counters=FrameUpdateStatistics()

    init(slotCount: Int=3) {
        precondition(slotCount > 0 && slotCount <= 16)
        damage=Array(repeating:nil,count:slotCount)
    }
    var state: FrameUpdateState? { lock.lock(); defer { lock.unlock() }; return current }
    var framesReceived: Int { lock.lock(); defer { lock.unlock() }; return counters.updates }
    var statistics: FrameUpdateStatistics { lock.lock(); defer { lock.unlock() }; return counters }

    @discardableResult
    func receive(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, dirty: FrameRegion?=nil) -> Bool {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width*height <= (256*1024*1024)/4, stride >= width*4,
              stride <= Int.max/height else { return false }
        let full=FrameRegion(x:0,y:0,width:width,height:height)
        guard let requested=(dirty ?? full).clipped(width:width,height:height) else { return false }
        lock.lock(); defer { lock.unlock() }
        let resized=current?.width != width || current?.height != height
        let changed: FrameRegion
        if resized {
            generation &+= 1
            pixels=Data(count:width*height*4)
            damage=Array(repeating:full,count:damage.count)
            // A callback always supplies the complete native framebuffer. A
            // partial first callback must initialize unchanged pixels as well.
            changed=full
        } else { changed=requested }
        pixels.withUnsafeMutableBytes { destination in
            let base=destination.baseAddress!
            if changed == full && stride == width*4 {
                base.copyMemory(from:bytes,byteCount:full.byteCount)
            } else {
                for row in changed.y..<(changed.y+changed.height) {
                    base.advanced(by:(row*width+changed.x)*4)
                        .copyMemory(from:bytes.advanced(by:row*stride+changed.x*4),byteCount:changed.width*4)
                }
            }
        }
        for index in damage.indices { damage[index]=damage[index].map { $0.union(changed) } ?? changed }
        counters.updates += 1
        counters.copiedBytes += changed.byteCount
        current=FrameUpdateState(width:width,height:height,sequence:counters.updates,generation:generation)
        return true
    }

    func hasPending(slot: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return damage.indices.contains(slot) && damage[slot] != nil
    }
    /// Upload synchronously from the owned image while locked. The pointer is
    /// already offset to the damaged region and is valid only inside the body;
    /// row stride remains the complete image's stride. The body must not call
    /// back into this store or retain the pointer. Metal's synchronous replace
    /// copies into an available texture before the native worker can mutate it.
    /// A rejected/failed upload leaves the slot's damage available for retry.
    func withUpdate(slot: Int, expectedGeneration: UInt64?=nil,
                    _ upload: (UnsafeRawPointer, Int, FrameRegion, FrameUpdateState) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard damage.indices.contains(slot), let current=current,
              expectedGeneration == nil || expectedGeneration == current.generation,
              let region=damage[slot] else { return false }
        let success=pixels.withUnsafeBytes { source in
            upload(source.baseAddress!.advanced(by:(region.y*current.width+region.x)*4),
                   current.width*4,region,current)
        }
        guard success else { return false }
        damage[slot]=nil
        counters.directUploadBytes += region.byteCount
        return true
    }
    /// Detach exactly the chosen slot's damage. Receives arriving after this
    /// snapshot accumulate new damage, including while that texture is in flight.
    func takeUpdate(slot: Int, expectedGeneration: UInt64?=nil) -> FrameUpload? {
        lock.lock(); defer { lock.unlock() }
        guard damage.indices.contains(slot), let current=current,
              expectedGeneration == nil || expectedGeneration == current.generation,
              let region=damage[slot] else { return nil }
        var snapshot=Data(count:region.byteCount)
        snapshot.withUnsafeMutableBytes { destination in
            pixels.withUnsafeBytes { source in
                for row in 0..<region.height {
                    destination.baseAddress!.advanced(by:row*region.width*4)
                        .copyMemory(from:source.baseAddress!.advanced(by:((row+region.y)*current.width+region.x)*4),
                                    byteCount:region.width*4)
                }
            }
        }
        damage[slot]=nil
        counters.snapshotBytes += region.byteCount
        if region.width == current.width && region.height == current.height { counters.fullSnapshots += 1 }
        else { counters.partialSnapshots += 1 }
        return FrameUpload(data:snapshot,region:region,state:current)
    }
    func invalidate(slot: Int) {
        lock.lock(); defer { lock.unlock() }
        guard damage.indices.contains(slot), let current=current else { return }
        damage[slot]=FrameRegion(x:0,y:0,width:current.width,height:current.height)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pixels=Data();current=nil
        damage=Array(repeating:nil,count:damage.count)
        counters=FrameUpdateStatistics()
    }
}
