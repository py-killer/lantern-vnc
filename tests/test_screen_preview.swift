// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics

@main
struct ScreenPreviewTests {
    static var checks=0
    static func expect(_ value:@autoclosure()->Bool,_ message:String) {
        checks+=1
        if !value() { fatalError("Screen preview: \(message)") }
    }
    static func source(width:Int,height:Int,stride:Int) -> [UInt8] {
        var bytes=[UInt8](repeating:0xee,count:stride*height)
        for y in 0..<height { for x in 0..<width {
            let offset=y*stride+x*4
            bytes[offset]=UInt8(truncatingIfNeeded:x*11+y*7)
            bytes[offset+1]=UInt8(truncatingIfNeeded:x*3+y*17)
            bytes[offset+2]=UInt8(truncatingIfNeeded:x*31+y*5)
            bytes[offset+3]=UInt8(truncatingIfNeeded:x+y)
        } }
        return bytes
    }
    static func sample(_ sampler:ScreenPreviewSampler,_ bytes:[UInt8],width:Int,height:Int,stride:Int,force:Bool=false,now:TimeInterval=10)->ScreenPreview? {
        bytes.withUnsafeBufferPointer { sampler.sample($0.baseAddress!,width:width,height:height,stride:stride,force:force,now:now) }
    }
    static func main() {
        let sampler=ScreenPreviewSampler(maxWidth:2,maxHeight:2)
        expect(!sampler.hasSample,"new sampler has no owned preview")
        var bytes=source(width:4,height:2,stride:20)
        guard let preview=sample(sampler,bytes,width:4,height:2,stride:20) else { fatalError("initial preview missing") }
        expect(sampler.hasSample,"a valid sample records preview availability")
        expect(preview.width==2 && preview.height==1,"4:2 image preserves aspect at 2:1")
        let expected=Data([UInt8(18),20,36,2,40,26,98,4]) // Centers (1,1) and (3,1), B,G,R,X.
        expect(preview.data==expected,"center sampling preserves pixel order and skips source-row padding")
        expect(preview.bytesPerRow==8 && preview.sampledAt==10,"packed owned metadata")
        expect(preview.cgImage.width==2 && preview.cgImage.height==1,"CGImage matches owned pixels")
        expect(preview.cgImage.alphaInfo == .noneSkipFirst,"framebuffer padding cannot make preview transparent")
        bytes=[UInt8](repeating:0,count:40)
        expect(preview.data==expected,"borrowed source mutation cannot change owned preview")
        expect((preview.cgImage.dataProvider!.data! as Data)==expected,"image provider owns thumbnail data")
        var rgba=[UInt8](repeating:0,count:8)
        rgba.withUnsafeMutableBytes { target in
            guard let context=CGContext(data:target.baseAddress,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("CGContext unavailable") }
            context.interpolationQuality = .none
            context.draw(preview.cgImage,in:CGRect(x:0,y:0,width:2,height:1))
        }
        expect(rgba == [36,20,18,255,98,26,40,255],"CGImage displays BGRX as opaque RGB")

        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:12)==nil,"default sampling does not repeat at the former two-second cadence")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:19.999)==nil,"default sampling waits the full ten seconds")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:20) != nil,"sample exactly at ten-second default interval")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,force:true,now:20.01) != nil,"forced connection preview bypasses throttle")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:20.02)==nil,"forced preview starts new throttle interval")
        sampler.reset()
        expect(!sampler.hasSample,"reset removes preview availability")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:1) != nil,"reset permits a new connection immediately")
        expect(sample(sampler,bytes,width:4,height:2,stride:20,now:0.5)==nil,"backward clock cannot bypass throttle")
        let tooFast=ScreenPreviewSampler(minimumInterval:0)
        expect(sample(tooFast,bytes,width:4,height:2,stride:20,now:0) != nil,"zero-time first sample allowed")
        expect(sample(tooFast,bytes,width:4,height:2,stride:20,now:1)==nil,"configuration cannot sample more often than two seconds")
        let fastFixture=ScreenPreviewSampler(minimumInterval:2)
        expect(sample(fastFixture,bytes,width:4,height:2,stride:20,now:0) != nil,"explicit faster fixture starts immediately")
        expect(sample(fastFixture,bytes,width:4,height:2,stride:20,now:1.999)==nil,"explicit faster fixture still enforces its interval")
        expect(sample(fastFixture,bytes,width:4,height:2,stride:20,now:2) != nil,"explicit two-second fixture remains supported")
        let slower=ScreenPreviewSampler(minimumInterval:4)
        expect(sample(slower,bytes,width:4,height:2,stride:20,now:0) != nil,"custom slower interval starts")
        expect(sample(slower,bytes,width:4,height:2,stride:20,now:2)==nil,"custom slower interval enforced")
        expect(sample(slower,bytes,width:4,height:2,stride:20,now:4) != nil,"custom interval expires")

        let validation=ScreenPreviewSampler()
        for (width,height,stride) in [(0,1,4),(-1,1,4),(1,0,4),(4,2,15),(16385,1,65540),(16384,16384,65536),(1,2,Int.max),(Int.max,1,4)] {
            expect(sample(validation,[0],width:width,height:height,stride:stride)==nil,"reject invalid dimensions/stride before pointer read")
        }
        for time in [Double.nan,Double.infinity,-1] {
            expect(sample(validation,bytes,width:4,height:2,stride:20,now:time)==nil,"reject invalid clock")
        }
        expect(!validation.hasSample,"invalid frames and clocks do not report a sample")
        expect(sample(validation,bytes,width:4,height:2,stride:20) != nil,"rejections never consume throttle")
        for (width,height,expectedWidth,expectedHeight) in [(5120,2880,480,270),(4000,3000,360,270),(1080,1920,152,270),
                                                         (320,200,320,200),(1001,777,348,270),(1,16384,1,270),(16384,1,480,1)] {
            let row=width*4+8,pixels=source(width:width,height:height,stride:row)
            let result=sample(ScreenPreviewSampler(),pixels,width:width,height:height,stride:row)!
            expect(result.width==expectedWidth && result.height==expectedHeight,"aspect-preserving bounded dimensions \(width)x\(height)")
            expect(result.width<=480 && result.height<=270 && result.width<=width && result.height<=height,"bounded preview never upscales")
            expect(result.data.count==result.width*result.height*4 && result.data.count<=480*270*4,"owned memory bounded by thumbnail dimensions")
            expect(abs(result.width*height-result.height*width)<=max(width,height),"aspect differs by at most one output pixel")
        }

        final class Count { let lock=NSLock();var value=0;func add(){lock.lock();value+=1;lock.unlock()} }
        let shared=ScreenPreviewSampler(),group=DispatchGroup(),count=Count()
        let sharedBytes=source(width:16,height:12,stride:68)
        sharedBytes.withUnsafeBufferPointer { buffer in
            for _ in 0..<32 {
                group.enter();DispatchQueue.global().async {
                    if let image=shared.sample(buffer.baseAddress!,width:16,height:12,stride:68,now:42) {
                        if image.data.count != 16*12*4 { fatalError("concurrent preview corrupted") }
                        count.add()
                    }
                    group.leave()
                }
            }
            let finished=group.wait(timeout:.now()+5)
            expect(finished == .success,"concurrent sampling completes without deadlock")
        }
        expect(count.value==1,"concurrent calls share one throttle decision")
        expect(shared.hasSample,"concurrent sampling publishes availability under the same lock")
        shared.reset()
        expect(sample(shared,sharedBytes,width:16,height:12,stride:68,now:42) != nil,"reset after concurrent use")
        print("PASS: \(checks) screen-preview checks; owned pixels, aspect, opacity, bounds, throttle and concurrent sampling")
    }
}
