// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CoreVideo
import VideoToolbox
import UniformTypeIdentifiers

/// Converts videos into lightweight, slide-friendly animated GIFs.
public final class VideoToGIFConverter {
    public static let shared = VideoToGIFConverter()

    private let conversionQueue = DispatchQueue(label: "com.que.gifconverter", qos: .userInitiated)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init() {}

    private final class DurationBox: @unchecked Sendable { var seconds: Double = 0 }

    /// Blocks the calling (background) thread until the asset duration is loaded. Returns 0 on failure.
    private static func loadDurationSeconds(_ asset: AVURLAsset) -> Double {
        let box = DurationBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            if let duration = try? await asset.load(.duration) {
                box.seconds = CMTimeGetSeconds(duration)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.seconds
    }

    // MARK: - Local file -> GIF

    /// Converts a local video file into an animated GIF Data in the background, starting `start` seconds in
    /// (0 = the instant GIF; the GIF editor passes the chosen moment). `completion` is always called on the main queue.
    public func convert(
        videoURL: URL,
        start: Double = 0,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        conversionQueue.async {
            let asset = AVURLAsset(url: videoURL)
            // AUDIT: AVAsset.duration is deprecated (macOS 13). Use load(.duration); we are on our own
            // serial queue here (never main), so blocking for the result is safe.
            let durationSeconds = Self.loadDurationSeconds(asset)
            guard durationSeconds > 0 && !durationSeconds.isNaN else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            let times = Self.frameTimes(start: start, length: maxDuration, sourceDuration: durationSeconds, fps: fps)
            let frameDuration = 1.0 / fps

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
            // FIX: .zero tolerance forces an exact-frame seek (decode from the previous keyframe)
            // for every one of ~56 frames, which is very slow and pointless for a 14fps GIF.
            // Half a frame interval of slack lets the decoder reuse nearby frames.
            let tolerance = CMTime(seconds: frameDuration / 2.0, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            var frames: [CGImage] = []
            frames.reserveCapacity(times.count)
            for seconds in times {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                // FIX: autoreleasepool keeps peak memory flat across the loop.
                autoreleasepool {
                    if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                        // Normalise to sRGB / maxWidth once here (encode no longer re-scales every frame).
                        frames.append(self.scaledCopy(image, maxDimension: maxWidth) ?? image)
                    }
                }
            }

            guard !frames.isEmpty,
                  let finalData = self.encodeImagesToGIF(frames: frames, count: frames.count, delays: nil, fps: fps) else {
                DispatchQueue.main.async { completion(nil, 0) }
                return
            }

            DispatchQueue.main.async {
                completion(finalData, finalData.count)
            }
        }
    }

    /// The source times (seconds) sampled for a GIF of up to `length` seconds starting at `start`, clamped to the video.
    /// Empty when `start` is past the end.
    public static func frameTimes(start: Double, length: Double, sourceDuration: Double, fps: Double) -> [Double] {
        let from = max(0, start)
        let span = min(sourceDuration - from, length)
        guard span > 0, fps > 0 else { return [] }
        return (0..<max(1, Int(span * fps))).map { from + Double($0) / fps }
    }

    // MARK: - HLS stream -> GIF

    /// Converts an HLS (.m3u8) stream into an animated GIF Data (real-time capture, so it takes
    /// about `maxDuration` seconds). `completion` is always called on the main queue.
    public func convertHLS(
        streamURL: URL,
        maxDuration: Double = 4.0,
        fps: Double = 14.0,
        maxWidth: CGFloat = 500.0,
        completion: @escaping (Data?, Int) -> Void
    ) {
        // FIX: callers invoke this from URLSession callback threads. Timer.scheduledTimer there
        // attaches to a runloop nobody runs (it only worked because of the extra RunLoop.main.add).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.convertHLS(streamURL: streamURL, maxDuration: maxDuration, fps: fps,
                                 maxWidth: maxWidth, completion: completion)
            }
            return
        }

        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true   // FIX: the original played the video's audio out loud while converting

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        player.play()

        let frameInterval = 1.0 / fps
        let targetFrameCount = max(1, Int(maxDuration * fps))
        let deadline = CACurrentMediaTime() + max(12.0, maxDuration * 3.0)

        var frames: [CGImage] = []
        var stamps: [Double] = []              // media time of each captured frame
        var lastCaptured = -Double.infinity

        let timer = Timer(timeInterval: frameInterval / 2.0, repeats: true) { [weak self] t in
            let failed = item.status == .failed          // FIX: fail fast instead of waiting out the deadline
            let mediaTime = item.currentTime()
            let seconds = CMTimeGetSeconds(mediaTime)

            // FIX: sample on *media* time, not wall-clock ticks. A stalled main runloop or a
            // buffering stream used to produce duplicated/missing frames and a sped-up GIF.
            if !failed, seconds.isFinite, seconds - lastCaptured >= frameInterval * 0.95,
               output.hasNewPixelBuffer(forItemTime: mediaTime),
               let buffer = output.copyPixelBuffer(forItemTime: mediaTime, itemTimeForDisplay: nil) {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cg)
                // FIX: downscale into our own bitmap immediately. (a) Native 720p/1080p frames
                // were kept in `frames` (~3.7-8 MB each, up to ~450 MB for 56 frames);
                // (b) the VT-created CGImage can keep the CVPixelBuffer alive, starving the
                // output's buffer pool.
                if let cg = cg, let small = self?.scaledCopy(cg, maxDimension: maxWidth) {
                    frames.append(small)
                    stamps.append(seconds)
                    lastCaptured = seconds
                }
            }

            guard frames.count >= targetFrameCount || failed || CACurrentMediaTime() > deadline else { return }

            t.invalidate()
            item.remove(output)
            player.pause()
            player.replaceCurrentItem(with: nil)   // release the HLS connection + buffers right away

            guard let self = self, !frames.isEmpty else {
                completion(nil, 0)
                return
            }

            // Per-frame delays from real timestamps so playback speed matches the source.
            var delays: [Double] = []
            for i in 0..<stamps.count {
                delays.append(i + 1 < stamps.count ? stamps[i + 1] - stamps[i] : frameInterval)
            }
            let captured = frames
            frames.removeAll()

            self.conversionQueue.async {
                let gifData = self.encodeImagesToGIF(frames: captured, count: captured.count, delays: delays, fps: fps)
                DispatchQueue.main.async {
                    completion(gifData, gifData?.count ?? 0)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Images -> GIF

    /// A looping slideshow GIF of `imageURLs` in order, each held `secondsEach`. `completion` is called on the main queue.
    public func makeSlideshow(imageURLs: [URL], secondsEach: Double, completion: @escaping (Data?) -> Void) {
        conversionQueue.async {
            let data = self.slideshowGIF(imageURLs: imageURLs, secondsEach: secondsEach)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// GIF frames share one size, so every image is fitted (not cropped) onto the first image's shape over white, sized
    /// for the largest image (up to `maxDimension`) so a small first image doesn't shrink the rest.
    /// A GIF in the list adds its first frame. nil if any image can't be read.
    public func slideshowGIF(imageURLs: [URL], secondsEach: Double, maxDimension: CGFloat = 1200) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,   // camera rotation
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension]
        let sources = imageURLs.compactMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        guard sources.count == imageURLs.count, secondsEach > 0,
              let first = sources.first.flatMap({ CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }) else { return nil }
        // Sizes from the files' headers: decoding every image up front could hold a gigabyte for a big selection.
        let longest = sources.map { source -> CGFloat in
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0, h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
            return min(maxDimension, max(w, h))
        }.max() ?? 0
        let scale = max(longest, CGFloat(max(first.width, first.height))) / CGFloat(max(first.width, first.height))
        let canvas = CGSize(width: (CGFloat(first.width) * scale).rounded(), height: (CGFloat(first.height) * scale).rounded())
        // Frames are made one at a time as the encoder takes them, so only one is held in memory.
        var made = 0
        let frames = sources.lazy.compactMap { source -> CGImage? in
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let frame = self.fittedCopy(image, canvas: canvas) else { return nil }
            made += 1
            return frame
        }
        let data = encodeImagesToGIF(frames: frames, count: sources.count, delays: nil, fps: 1 / secondsEach)
        return made == sources.count ? data : nil
    }

    /// Draws `image` aspect-fitted and centred on a white `canvas`-sized 8-bit sRGB bitmap.
    private func fittedCopy(_ image: CGImage, canvas: CGSize) -> CGImage? {
        let w = Int(canvas.width), h = Int(canvas.height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard w > 0, h > 0, image.width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.sRGB, bitmapInfo: bitmapInfo) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let scale = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let dw = CGFloat(image.width) * scale, dh = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (canvas.width - dw) / 2, y: (canvas.height - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    // MARK: - Encoding

    /// Draws `image` into a fresh 8-bit sRGB bitmap that fits inside `maxDimension` x `maxDimension`.
    /// FIX: the original built its CGContext from the *source* frame's bitsPerComponent / colorSpace /
    /// bitmapInfo, which can fail for video-derived images (then it silently kept the full-size
    /// frame), and left wide-gamut video colors untagged for GIF (visible color shift in Slides).
    private func scaledCopy(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w0 = CGFloat(image.width), h0 = CGFloat(image.height)
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w0, h0))
        let w = max(1, Int((w0 * scale).rounded()))
        let h = max(1, Int((h0 * scale).rounded()))

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.sRGB, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Assembles already-scaled frames into a looping GIF. `delays` (seconds per frame) is optional; nil = uniform 1/fps.
    private func encodeImagesToGIF<Frames: Sequence>(frames: Frames, count: Int, delays: [Double]?, fps: Double) -> Data?
    where Frames.Element == CGImage {
        guard count > 0 else { return nil }

        let gifData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            gifData as CFMutableData,
            UTType.gif.identifier as CFString,
            count,
            nil
        ) else { return nil }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0 // Infinite loop
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let uniformDelay = 1.0 / fps
        for (i, frame) in frames.enumerated() {   // a lazy sequence makes each frame only here
            // GIF delays are centiseconds; browsers/Slides clamp < 2cs, so don't go below that.
            let delay = max(0.02, delays?[i] ?? uniformDelay)
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delay,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delay
                ]
            ]
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        let success = CGImageDestinationFinalize(destination)
        return (success && gifData.length > 0) ? (gifData as Data) : nil
    }
}

