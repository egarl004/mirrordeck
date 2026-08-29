import Foundation
import AVFoundation
import CoreMedia

/// Turns Annex-B H.264 access units from the receiver into CMSampleBuffers
/// and enqueues them on an AVSampleBufferDisplayLayer (which hardware-decodes
/// compressed H.264 itself — no explicit VTDecompressionSession needed).
final class VideoPipeline {
    weak var displayLayer: AVSampleBufferDisplayLayer?
    /// Reported on the main thread whenever the coded video size changes.
    var onDimensions: ((Int, Int) -> Void)?

    private let queue = DispatchQueue(label: "mirrordeck.video", qos: .userInteractive)
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var lastReportedSize: (Int, Int) = (0, 0)

    /// Safe to call from any thread; copies the frame and processes async.
    func handleAccessUnit(_ bytes: UnsafePointer<UInt8>, _ length: Int) {
        let data = Data(bytes: bytes, count: length)
        queue.async { [weak self] in
            self?.process(data)
        }
    }

    func flush() {
        queue.async { [weak self] in
            self?.displayLayer?.flush()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayLayer?.flush()
            self.formatDescription = nil
            self.sps = nil
            self.pps = nil
        }
    }

    // MARK: - Parsing

    private func process(_ frame: Data) {
        var vclUnits: [Data] = []
        var parameterSetsChanged = false

        for nal in VideoPipeline.splitAnnexB(frame) {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            switch nalType {
            case 7:
                if sps != nal { sps = nal; parameterSetsChanged = true }
            case 8:
                if pps != nal { pps = nal; parameterSetsChanged = true }
            case 1, 5:
                vclUnits.append(nal)
            default:
                break // SEI / AUD etc. are not needed for display
            }
        }

        if parameterSetsChanged || formatDescription == nil {
            rebuildFormatDescription()
        }
        guard let formatDescription, !vclUnits.isEmpty else { return }
        guard let sampleBuffer = makeSampleBuffer(vclUnits, format: formatDescription) else { return }

        if let layer = displayLayer {
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sampleBuffer)
        }
    }

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr -> OSStatus in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { return }
        formatDescription = format

        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let size = (Int(dims.width), Int(dims.height))
        if size != lastReportedSize {
            lastReportedSize = size
            DispatchQueue.main.async { [weak self] in
                self?.onDimensions?(size.0, size.1)
            }
        }
    }

    private func makeSampleBuffer(_ nalUnits: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // AVCC layout: 4-byte big-endian length prefix per NAL unit.
        var avcc = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            var lengthBE = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let count = avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        // Display each frame as soon as it decodes — lowest possible latency.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
           let dict = attachments.first {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    /// Splits an Annex-B byte stream into NAL unit payloads (start codes removed).
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var currentStart: Int? = nil
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let startCodeLength = (i > 0 && bytes[i - 1] == 0) ? 4 : 3
                let boundary = startCodeLength == 4 ? i - 1 : i
                if let start = currentStart, boundary > start {
                    units.append(Data(bytes[start..<boundary]))
                }
                i += 3
                currentStart = i
            } else {
                i += 1
            }
        }
        if let start = currentStart, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }
}
