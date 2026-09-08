import Foundation
import Compression

/// Decodes a coach's plan link (`PLAN-FORMAT.md` v1) into a typed payload.
///
/// Mirrors `CoachShare.swift`'s encode side in reverse — base64url, then raw
/// DEFLATE (`COMPRESSION_ZLIB` used as a raw/no-wrap codec, matching
/// `CompressionStream('deflate-raw')` and Android's `Inflater(nowrap = true)`)
/// — but is written independently rather than by exposing CoachShare's
/// private helpers, so a fixture built one way and decoded the other way
/// actually exercises interop, not just round-tripping through the same code.
enum PlanLinkCodec {

    /// - Parameter fragment: everything after the `#` in a plan link, without
    ///   the leading `#` itself.
    /// - Parameter expectedLifterID: this device's own `CoachShare.Settings.lifterID`.
    static func decode(fragment: String, expectedLifterID: String) throws -> PlanPayload {
        guard fragment.count >= 2 else { throw PlanLinkError.malformedFragment }

        let version = fragment[fragment.startIndex]
        let codec = fragment[fragment.index(after: fragment.startIndex)]
        // "Decoders must ignore any characters after the payload" — but the
        // payload itself is base64url, so the first non-base64url character
        // (if any) marks where it ends.
        let rest = fragment.dropFirst(2)
        let payloadString = String(rest.prefix { isBase64URLCharacter($0) })

        guard version == "1" else {
            throw PlanLinkError.unsupportedVersion(String(version))
        }

        guard let payloadData = base64URLDecode(payloadString) else {
            throw PlanLinkError.corruptPayload
        }

        let jsonData: Data
        switch codec {
        case "z":
            guard let inflated = inflateRaw(payloadData) else { throw PlanLinkError.corruptPayload }
            jsonData = inflated
        case "u":
            jsonData = payloadData
        default:
            throw PlanLinkError.unsupportedCodec(String(codec))
        }

        let payload: PlanPayload
        do {
            payload = try JSONDecoder().decode(PlanPayload.self, from: jsonData)
        } catch {
            throw PlanLinkError.corruptPayload
        }

        guard payload.v == 1 else { throw PlanLinkError.unsupportedVersion(String(payload.v)) }
        // `t` exists specifically to "distinguish this from a log arriving at
        // the same door" (PLAN-FORMAT.md) — a coach log link
        // (CoachShare.swift's `/coach/#1z...`) decodes to valid JSON shaped
        // enough like a plan payload that this must be checked explicitly,
        // not assumed from the URL alone.
        guard payload.t == "plan" else { throw PlanLinkError.corruptPayload }
        guard payload.l == expectedLifterID else { throw PlanLinkError.notAddressedToThisDevice }

        return payload
    }

    private static func isBase64URLCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    /// Grows the output buffer and retries — `compression_decode_buffer` gives
    /// no way to ask "how big will this be", unlike a streaming API.
    private static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(data.count * 4, 4096)
        let maxCapacity = 16 * 1024 * 1024

        while capacity <= maxCapacity {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }

            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity, base, data.count, nil, COMPRESSION_ZLIB
                )
            }

            if written > 0 && written < capacity {
                return Data(bytes: destination, count: written)
            }
            capacity *= 2
        }
        return nil
    }
}

enum PlanLinkError: Error, Equatable {
    case malformedFragment
    case unsupportedVersion(String)
    case unsupportedCodec(String)
    case corruptPayload
    case notAddressedToThisDevice
}

struct PlanPayload: Decodable, Equatable {
    let v: Int
    let t: String
    let l: String
    let n: String
    let r: [PlanRecipe]?
    let m: [PlanMeal]?
    let w: [PlanWorkout]?
    let k: [PlanSession]?
}

struct PlanRecipe: Decodable, Equatable {
    let n: String
    let s: Double
    let u: [Double]?
    let i: [String]?
    let t: [String]?
}

struct PlanMeal: Decodable, Equatable {
    let d: String
    let s: Int
    let x: Int
    let q: Double
}

struct PlanWorkout: Decodable, Equatable {
    let n: String
    let e: [PlanWorkoutExercise]
}

struct PlanWorkoutExercise: Decodable, Equatable {
    let n: String
    let q: String?
    let c: String?
    let s: [[Double?]]
}

struct PlanSession: Decodable, Equatable {
    let d: String
    let x: Int
}
