import Foundation
import Compression
import Display
import SwiftSignalKit
import UniversalMediaPlayer
import CoreMedia
import ManagedFile
import Accelerate
import TelegramCore
import WebPBinding
import UIKit

private let sharedStoreQueue = Queue.concurrentDefaultQueue()

private let maximumFrameCount = 30 * 10

private final class VideoStickerFrameSourceCache {
    private enum FrameRangeResult {
        case range(Range<Int>)
        case notFound
        case corruptedFile
    }
    
    private let queue: Queue
    private let storeQueue: Queue
    private let path: String
    private let file: ManagedFile
    private let width: Int
    private let height: Int
    
    public private(set) var frameRate: Int32 = 0
    public private(set) var frameCount: Int32 = 0
    
    private var isStoringFrames = Set<Int>()
    var storedFrames: Int {
        return self.isStoringFrames.count
    }
    
    private var scratchBuffer: Data
    private var decodeBuffer: Data
    
    init?(queue: Queue, pathPrefix: String, width: Int, height: Int) {
        self.queue = queue
        self.storeQueue = sharedStoreQueue
        
        self.width = width
        self.height = height
        
        let version: Int = 3
        self.path = "\(pathPrefix)_\(width)x\(height)-v\(version).vstickerframecache"
        var file = ManagedFile(queue: queue, path: self.path, mode: .readwrite)
        if let file = file {
            self.file = file
        } else {
            let _ = try? FileManager.default.removeItem(atPath: self.path)
            file = ManagedFile(queue: queue, path: self.path, mode: .readwrite)
            if let file = file {
                self.file = file
            } else {
                return nil
            }
        }
        
        self.scratchBuffer = Data(count: compression_decode_scratch_buffer_size(COMPRESSION_LZFSE))
        
        let yuvaPixelsPerAlphaRow = (Int(width) + 1) & (~1)
        let yuvaLength = Int(width) * Int(height) * 2 + yuvaPixelsPerAlphaRow * Int(height) / 2
        self.decodeBuffer = Data(count: yuvaLength)
        
        self.initializeFrameTable()
    }
    
    deinit {
        if self.frameCount == 0 {
            let _ = try? FileManager.default.removeItem(atPath: self.path)
        }
    }
    
    private func initializeFrameTable() {
        var reset = true
        if let size = self.file.getSize(), size >= maximumFrameCount {
            if self.readFrameRate() {
                reset = false
            }
        }
        if reset {
            self.file.truncate(count: 0)
            var zero: Int32 = 0
            let _ = self.file.write(&zero, count: 4)
            let _ = self.file.write(&zero, count: 4)
            
            for _ in 0 ..< maximumFrameCount {
                let _ = self.file.write(&zero, count: 4)
                let _ = self.file.write(&zero, count: 4)
            }
        }
    }
    
    private func readFrameRate() -> Bool {
        guard self.frameCount == 0 else {
            return true
        }
       
        let _ = self.file.seek(position: 0)
        var frameRate: Int32 = 0
        if self.file.read(&frameRate, 4) != 4 {
            return false
        }
        if frameRate < 0 {
            return false
        }
        if frameRate == 0 {
            return false
        }
        self.frameRate = frameRate
        
        let _ = self.file.seek(position: 4)
        
        var frameCount: Int32 = 0
        if self.file.read(&frameCount, 4) != 4 {
            return false
        }
        
        if frameCount < 0 {
            return false
        }
        if frameCount == 0 {
            return false
        }
        self.frameCount = frameCount
        
        return true
    }
    
    private func readFrameRange(index: Int) -> FrameRangeResult {
        if index < 0 || index >= maximumFrameCount {
            return .notFound
        }
        
        guard self.readFrameRate() else {
            return .notFound
        }
                
        if index >= self.frameCount {
            return .notFound
        }
        
        let _ = self.file.seek(position: Int64(8 + index * 4 * 2))
        var offset: Int32 = 0
        var length: Int32 = 0
        if self.file.read(&offset, 4) != 4 {
            return .corruptedFile
        }
        if self.file.read(&length, 4) != 4 {
            return .corruptedFile
        }
        if length == 0 {
            return .notFound
        }
        if length < 0 || offset < 0 {
            return .corruptedFile
        }
        if Int64(offset) + Int64(length) > 100 * 1024 * 1024 {
            return .corruptedFile
        }
        
        return .range(Int(offset) ..< Int(offset + length))
    }
    
    func storeFrameRateAndCount(frameRate: Int, frameCount: Int) {
        let _ = self.file.seek(position: 0)
        var frameRate = Int32(frameRate)
        let _ = self.file.write(&frameRate, count: 4)
       
        let _ = self.file.seek(position: 4)
        var frameCount = Int32(frameCount)
        let _ = self.file.write(&frameCount, count: 4)
    }
    
    func storeUncompressedRgbFrame(index: Int, rgbData: Data) {
        if index < 0 || index >= maximumFrameCount {
            return
        }
        if self.isStoringFrames.contains(index) {
            return
        }
        self.isStoringFrames.insert(index)
        
        let width = self.width
        let height = self.height
        
        let queue = self.queue
        self.storeQueue.async { [weak self] in
            let compressedData = compressFrame(width: width, height: height, rgbData: rgbData, unpremultiply: false)
            
            queue.async {
                guard let strongSelf = self else {
                    return
                }
                guard let currentSize = strongSelf.file.getSize() else {
                    return
                }
                guard let compressedData = compressedData else {
                    return
                }
                
                let _ = strongSelf.file.seek(position: Int64(8 + index * 4 * 2))
                var offset = Int32(currentSize)
                var length = Int32(compressedData.count)
                let _ = strongSelf.file.write(&offset, count: 4)
                let _ = strongSelf.file.write(&length, count: 4)
                let _ = strongSelf.file.seek(position: Int64(currentSize))
                compressedData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
                    if let baseAddress = buffer.baseAddress {
                        let _ = strongSelf.file.write(baseAddress, count: Int(length))
                    }
                }
            }
        }
    }
    
    func readUncompressedYuvaFrame(index: Int) -> Data? {
        if index < 0 || index >= maximumFrameCount {
            return nil
        }
        let rangeResult = self.readFrameRange(index: index)
        
        switch rangeResult {
        case let .range(range):
            let _ = self.file.seek(position: Int64(range.lowerBound))
            let length = range.upperBound - range.lowerBound
            let compressedData = self.file.readData(count: length)
            if compressedData.count != length {
                return nil
            }
            
            var frameData: Data?
            
            let decodeBufferLength = self.decodeBuffer.count
            
            compressedData.withUnsafeBytes { buffer -> Void in
                guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                
                self.scratchBuffer.withUnsafeMutableBytes { scratchBuffer -> Void in
                    guard let scratchBytes = scratchBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }

                    self.decodeBuffer.withUnsafeMutableBytes { decodeBuffer -> Void in
                        guard let decodeBytes = decodeBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return
                        }

                        let resultLength = compression_decode_buffer(decodeBytes, decodeBufferLength, bytes, length, UnsafeMutableRawPointer(scratchBytes), COMPRESSION_LZFSE)
                        
                        frameData = Data(bytes: decodeBytes, count: resultLength)
                    }
                }
            }
            
            return frameData
        case .notFound:
            return nil
        case .corruptedFile:
            self.file.truncate(count: 0)
            self.initializeFrameTable()
            
            return nil
        }
    }
}

private let useCache = true

public func makeVideoStickerDirectFrameSource(queue: Queue, path: String, hintVP9: Bool, width: Int, height: Int, cachePathPrefix: String?, unpremultiplyAlpha: Bool) -> AnimatedStickerFrameSource? {
    return VideoStickerDirectFrameSource(queue: queue, path: path, isVP9: hintVP9, width: width, height: height, cachePathPrefix: cachePathPrefix, unpremultiplyAlpha: unpremultiplyAlpha)
}

public final class VideoStickerDirectFrameSource: AnimatedStickerFrameSource {
    private let queue: Queue
    private let path: String
    private let width: Int
    private let height: Int
    private let cache: VideoStickerFrameSourceCache?
    private let image: UIImage?
    private let bytesPerRow: Int
    public var frameCount: Int
    public let frameRate: Int
    public var duration: Double
    fileprivate var currentFrame: Int
    
    private var source: FFMpegFileReader?
    
    public var frameIndex: Int {
        if self.frameCount == 0 {
            return 0
        } else {
            return self.currentFrame % self.frameCount
        }
    }
    
    public init?(queue: Queue, path: String, isVP9: Bool = true, width: Int, height: Int, cachePathPrefix: String?, unpremultiplyAlpha: Bool = true) {
        self.queue = queue
        self.path = path
        self.width = width
        self.height = height
        self.bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: Int(self.width))
        self.currentFrame = 0
  
        self.cache = cachePathPrefix.flatMap { cachePathPrefix in
            VideoStickerFrameSourceCache(queue: queue, pathPrefix: cachePathPrefix, width: width, height: height)
        }
        
        if useCache, let cache = self.cache, cache.frameCount > 0 {
            self.source = nil
            self.image = nil
            self.frameRate = Int(cache.frameRate)
            self.frameCount = Int(cache.frameCount)
            if self.frameRate > 0 {
                self.duration = Double(self.frameCount) / Double(self.frameRate)
            } else {
                self.duration = 0.0
            }
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = WebP.convert(fromWebP: data) {
            self.source = nil
            self.image = image
            self.frameRate = 1
            self.frameCount = 1
            self.duration = 0.0
        } else {
            let source = FFMpegFileReader(
                source: .file(path),
                passthroughDecoder: false,
                useHardwareAcceleration: false,
                selectedStream: .mediaType(.video),
                seek: nil,
                maxReadablePts: nil
            )
            if let source {
                self.source = source
                self.frameRate = min(30, source.frameRate())
                self.duration = source.duration().seconds
            } else {
                self.source = nil
                self.frameRate = 30
                self.duration = 0.0
            }
            self.image = nil
            self.frameCount = 0
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
    }
    
    public func takeFrame(draw: Bool) -> AnimatedStickerFrame? {
        let frameIndex: Int
        if self.frameCount > 0 {
            frameIndex = self.currentFrame % self.frameCount
        } else {
            frameIndex = self.currentFrame
        }

        self.currentFrame += 1
        if draw {
            if let image = self.image {
                guard let context = DrawingContext(size: CGSize(width: self.width, height: self.height), scale: 1.0, opaque: false, clear: true, bytesPerRow: self.bytesPerRow) else {
                    return nil
                }
                context.withFlippedContext { c in
                    c.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: context.size))
                }
                let frameData = Data(bytes: context.bytes, count: self.bytesPerRow * self.height)
                                
                return AnimatedStickerFrame(data: frameData, type: .argb, width: self.width, height: self.height, bytesPerRow: self.bytesPerRow, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount, multiplyAlpha: true)
            } else if useCache, let cache = self.cache, let yuvData = cache.readUncompressedYuvaFrame(index: frameIndex) {
                return AnimatedStickerFrame(data: yuvData, type: .yuva, width: self.width, height: self.height, bytesPerRow: self.width * 2, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount)
            } else if let source = self.source {
                let frameAndLoop = source.readFrame(argb: true)
                switch frameAndLoop {
                case let .frame(frame):
                    var frameData = Data(count: self.bytesPerRow * self.height)
                    frameData.withUnsafeMutableBytes { buffer -> Void in
                        guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return
                        }
                        
                        let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)
                        CVPixelBufferLockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: 0))
                        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer!)
                        let width = CVPixelBufferGetWidth(imageBuffer!)
                        let height = CVPixelBufferGetHeight(imageBuffer!)
                        let srcData = CVPixelBufferGetBaseAddress(imageBuffer!)
                        
                        var sourceBuffer = vImage_Buffer(data: srcData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
                        var destBuffer = vImage_Buffer(data: bytes, height: vImagePixelCount(self.height), width: vImagePixelCount(self.width), rowBytes: self.bytesPerRow)
                                   
                        let _ = vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageDoNotTile))
                        
                        CVPixelBufferUnlockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: 0))
                    }

                    self.cache?.storeUncompressedRgbFrame(index: frameIndex, rgbData: frameData)
                                    
                    return AnimatedStickerFrame(data: frameData, type: .argb, width: self.width, height: self.height, bytesPerRow: self.bytesPerRow, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount, multiplyAlpha: true)
                case .endOfStream:
                    if self.frameCount == 0 {
                        if let cache = self.cache {
                            if cache.storedFrames == frameIndex {
                                self.frameCount = frameIndex
                                cache.storeFrameRateAndCount(frameRate: self.frameRate, frameCount: self.frameCount)
                            } else {
                                Logger.shared.log("VideoSticker", "Missed a frame? \(frameIndex) \(cache.storedFrames)")
                            }
                        } else {
                            self.frameCount = frameIndex
                        }
                    }
                    self.currentFrame = 0
                    self.source = FFMpegFileReader(
                        source: .file(self.path),
                        passthroughDecoder: false,
                        useHardwareAcceleration: false,
                        selectedStream: .mediaType(.video),
                        seek: nil,
                        maxReadablePts: nil
                    )
                    
                    if let cache = self.cache {
                        if let yuvData = cache.readUncompressedYuvaFrame(index: self.currentFrame) {
                            return AnimatedStickerFrame(data: yuvData, type: .yuva, width: self.width, height: self.height, bytesPerRow: self.width * 2, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount)
                        }
                    }
                    
                    return nil
                case .waitingForMoreData, .error:
                    return nil
                }
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    public func skipToEnd() {
        self.currentFrame = self.frameCount - 1
    }

    public func skipToFrameIndex(_ index: Int) {
        self.currentFrame = index
    }
}
