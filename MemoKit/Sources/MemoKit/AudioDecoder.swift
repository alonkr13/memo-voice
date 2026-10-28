import Foundation

public enum AudioDecoderError: Error, Equatable {
    case unreadable(String)
}

public enum AudioDecoder {
    public static func pcm16kMono(from url: URL) throws -> [Float] {
        []
    }
}
