//
//  PCMFeeder.swift
//  CloudTune
//
//  Decodes audio on a background queue and provides small PCM buffers
//  to the scheduler. Keeps a short look-ahead to avoid underruns.
//

import AVFoundation
import CoreMedia

final class PCMFeeder {

    // MARK: Config (tweakable)
    struct Config {
        /// 2048 @ 48kHz ~= 42.6 ms per buffer
        static let chunkFrames: AVAudioFrameCount = 2048
        /// 8 chunks ≈ ~340 ms of look-ahead
        static let maxPendingChunks = 8
    }

    // MARK: State
    private let decodeQ = DispatchQueue(label: "audio.decode.queue", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private(set) var isEOF: Bool = false
    private var cancelled = false

    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?

    private var targetFormat: AVAudioFormat?

    // MARK: Lifecycle

    /// Start decoding an audio file into float32, non-interleaved PCM matching the engine's output format.
    func startDecoding(url: URL, targetFormat: AVAudioFormat) {
        cancelled = false
        isEOF = false
        self.targetFormat = targetFormat
        lock.lock(); pending.removeAll(); lock.unlock()

        decodeQ.async { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = asset.tracks(withMediaType: .audio).first else {
                    self.finishEOF(); return
                }

                let reader = try AVAssetReader(asset: asset)
                self.assetReader = reader

                // Request Linear PCM that already matches our engine format
                let fmt = targetFormat
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: fmt.sampleRate,
                    AVNumberOfChannelsKey: fmt.channelCount,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: true,
                    AVLinearPCMIsBigEndianKey: false
                ]

                let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    print("❌ PCMFeeder: cannot add track output")
                    self.finishEOF(); return
                }
                reader.add(output)
                self.trackOutput = output

                guard reader.startReading() else {
                    print("❌ PCMFeeder: reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
                    self.finishEOF(); return
                }

                self.decodeLoop(targetFormat: fmt)
            } catch {
                print("❌ PCMFeeder: \(error.localizedDescription)")
                self.finishEOF()
            }
        }
    }

    func cancel() {
        cancelled = true
        decodeQ.async { [weak self] in self?.assetReader?.cancelReading() }
        lock.lock(); pending.removeAll(); lock.unlock()
        isEOF = true
    }

    // MARK: Consume

    func pop() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    // MARK: Private

    private func decodeLoop(targetFormat: AVAudioFormat) {
        guard let reader = assetReader,
              let output = trackOutput else {
            finishEOF(); return
        }

        var leftover: AVAudioPCMBuffer?

        while !cancelled {
            if reader.status == .completed { break }
            if reader.status == .failed || reader.status == .cancelled {
                print("⚠️ AssetReader status: \(reader.status.rawValue) err=\(reader.error?.localizedDescription ?? "none")")
                break
            }

            if pendingCount() >= Config.maxPendingChunks {
                usleep(2_000) // 2ms backoff
                continue
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break // drained
            }

            let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard numFrames > 0 else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            guard let fullBuf = makePCMBuffer(from: sampleBuffer, format: targetFormat) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            CMSampleBufferInvalidate(sampleBuffer)

            // Fill leftover first
            if let lf = leftover, lf.frameLength < Config.chunkFrames {
                let toCopy = min(Config.chunkFrames - lf.frameLength, fullBuf.frameLength)
                copyFrames(from: fullBuf, srcOffset: 0, to: lf, dstOffset: lf.frameLength, count: toCopy)
                lf.frameLength += toCopy
                if lf.frameLength == Config.chunkFrames {
                    enqueue(lf)
                    leftover = nil
                }
                if toCopy < fullBuf.frameLength {
                    fullBuf.trim(fromStart: toCopy)
                } else {
                    continue
                }
            }

            // Split into fixed chunks
            var cursor: AVAudioFrameCount = 0
            while cursor < fullBuf.frameLength {
                let remain = fullBuf.frameLength - cursor
                if remain >= Config.chunkFrames {
                    let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: Config.chunkFrames)!
                    copyFrames(from: fullBuf, srcOffset: cursor, to: buf, dstOffset: 0, count: Config.chunkFrames)
                    buf.frameLength = Config.chunkFrames
                    enqueue(buf)
                    cursor += Config.chunkFrames
                } else {
                    let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: Config.chunkFrames)!
                    copyFrames(from: fullBuf, srcOffset: cursor, to: buf, dstOffset: 0, count: remain)
                    buf.frameLength = remain
                    leftover = buf
                    cursor = fullBuf.frameLength
                }
            }
        }

        if let lf = leftover, lf.frameLength > 0 { enqueue(lf) }
        finishEOF()
    }

    private func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    private func enqueue(_ b: AVAudioPCMBuffer) {
        lock.lock(); pending.append(b); lock.unlock()
    }

    private func finishEOF() {
        isEOF = true
    }

    // MARK: - Buffer helpers

    /// Build an AVAudioPCMBuffer from a CMSampleBuffer containing Float32, non-interleaved LPCM.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numFrames) else { return nil }
        pcm.frameLength = numFrames

        var blockBuffer: CMBlockBuffer?
        var ablSize: Int = 0

        // 1) Ask for the required AudioBufferList size
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        if status != noErr { return nil }

        // 2) Allocate exactly that many bytes, then fetch the list
        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: ablPtr,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        if status != noErr { return nil }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        let channelCount = min(abl.count, Int(format.channelCount))

        // Because we requested non-interleaved float32, each AudioBuffer corresponds to one channel.
        for ch in 0..<channelCount {
            let audioBuffer = abl[ch]
            guard let src = audioBuffer.mData?.assumingMemoryBound(to: Float.self),
                  let dst = pcm.floatChannelData?[ch] else { continue }
            let bytes = Int(audioBuffer.mDataByteSize)
            let samples = min(Int(numFrames), bytes / MemoryLayout<Float>.size)
            dst.assign(from: src, count: samples)
        }
        return pcm
    }

    /// Copy 'count' frames from src @ srcOffset to dst @ dstOffset (float32, non-interleaved)
    private func copyFrames(from src: AVAudioPCMBuffer, srcOffset: AVAudioFrameCount,
                            to dst: AVAudioPCMBuffer,  dstOffset: AVAudioFrameCount,
                            count: AVAudioFrameCount) {
        let channels = Int(dst.format.channelCount)
        for ch in 0..<channels {
            guard let s = src.floatChannelData?[ch], let d = dst.floatChannelData?[ch] else { continue }
            let sp = s.advanced(by: Int(srcOffset))
            let dp = d.advanced(by: Int(dstOffset))
            dp.assign(from: sp, count: Int(count))
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Drop 'n' frames from the start (utility for trimming)
    func trim(fromStart n: AVAudioFrameCount) {
        guard n > 0, n <= frameLength else { return }
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            guard let d = floatChannelData?[ch] else { continue }
            let src = d.advanced(by: Int(n))
            d.assign(from: src, count: Int(frameLength - n))
        }
        frameLength -= n
    }
}
