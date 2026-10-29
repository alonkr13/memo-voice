import AVFoundation
import Foundation

public enum AudioDecoderError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "Cannot read audio file: \(m)"
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        }
    }
}

public enum AudioDecoder {
    public static let targetSampleRate: Double = 16_000

    /// Decodes any AVFoundation-readable audio file to 16 kHz mono Float samples in [-1, 1].
    /// Streams the source in chunks so long recordings never need one giant source-rate buffer.
    public static func pcm16kMono(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecoderError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let inFormat = file.processingFormat
        guard file.length > 0, inFormat.sampleRate > 0 else {
            throw AudioDecoderError.unreadable("\(url.lastPathComponent): file contains no audio")
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw AudioDecoderError.conversionFailed("unsupported format \(inFormat)")
        }

        let reader = ChunkReader(file: file, chunkFrames: 32_768)
        let outCapacity: AVAudioFrameCount = 16_384
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioDecoderError.conversionFailed("cannot allocate output buffer")
        }

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) / inFormat.sampleRate * targetSampleRate) + 1024)

        while true {
            outBuffer.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
                reader.next(inStatus)
            }
            if status == .error {
                throw AudioDecoderError.conversionFailed(
                    convError?.localizedDescription ?? "unknown error")
            }
            if let err = reader.readError {
                throw AudioDecoderError.unreadable(err.localizedDescription)
            }
            if outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(
                    start: ch[0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .haveData || status == .inputRanDry { continue }
        }

        for i in result.indices { result[i] = min(1, max(-1, result[i])) }
        return result
    }
}

/// Feeds the converter successive chunks of the source file. Used only synchronously
/// from the converter's input block on the calling thread.
private final class ChunkReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private(set) var readError: Error?

    init(file: AVAudioFile, chunkFrames: AVAudioFrameCount) {
        self.file = file
        self.buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)!
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if file.framePosition >= file.length {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            readError = error
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
