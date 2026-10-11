import Foundation
import Compression

/// Raw-DEFLATE + base64url, the envelope `SHARE-FORMAT.md` uses.
///
/// Ported from `lift-ios`'s `Sources/Shared/CoachShare.swift`. That is the
/// encoder the PWA's `planInflate` (`DecompressionStream('deflate-raw')`)
/// already reads, so the byte format is fixed by an existing consumer, not
/// chosen here. `COMPRESSION_ZLIB` is Apple's name for raw DEFLATE with no
/// zlib header — despite the name, it is the raw stream the browser wants.
public enum CompactEncoding {

    public static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count, 128)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        // Zero means it did not fit in `capacity`, i.e. compression made it
        // bigger. The caller sends the payload uncompressed in that case.
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
