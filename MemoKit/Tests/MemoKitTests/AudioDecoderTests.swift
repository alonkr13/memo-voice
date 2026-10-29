import AVFoundation
import Foundation
import Testing
@testable import MemoKit
@testable import MemoCore

@Suite struct AudioDecoderTests {
    /// Writes a 2 s 44.1 kHz stereo 440 Hz sine-tone AAC .m4a into a fresh temp dir.
    private func makeToneFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone-2s-44k-stereo.m4a")

        let sampleRate = 44_100.0
        let frames = AVAudioFrameCount(sampleRate * 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func testResamplesToMono16k() throws {
        let url = try makeToneFixture()
        let samples = try AudioDecoder.pcm16kMono(from: url)

        #expect(abs(samples.count - 32_000) <= 160)
        #expect(samples.allSatisfy { $0 >= -1 && $0 <= 1 })
        #expect((samples.map { abs($0) }.max() ?? 0) > 0.1)
    }

    @Test func testNonAudioBytesThrow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("junk.m4a")
        try Data("this is definitely not audio".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            _ = try AudioDecoder.pcm16kMono(from: url)
        }
    }
}
