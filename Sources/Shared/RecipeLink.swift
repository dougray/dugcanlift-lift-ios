import Foundation
import Compression
import LiftCore

/// An `r1` recipe link, as the "Send to LIFT" bookmarklet writes it: a port of
/// `dugcanlift-kit/bookmarklet/recipe-link.mjs`, the reference decoder every
/// build ports (the kit's `bookmarklet/README.md` is the contract).
///
///     dugcanliftlift://recipe#r1<base64url(deflate-raw(JSON)), no padding>
///     JSON = {"v":1,"url":"<page address>","jsonld":["<block text>", ...]}
///
/// It only unwraps. What comes out is exactly what Safari's share extension
/// hands LIFT -- the page's address and the raw text of its `ld+json` blocks,
/// a `SharedRecipePage` -- so the blocks go to the same `RecipeJSONLD` reader
/// and the same review a Safari share opens. Nothing is fetched: the browser
/// already had the page, and the address is only ever the recipe's source.
///
/// Refuses, returning nil, rather than guessing, on exactly what the reference
/// refuses: no `r1` prefix, bad base64url, bad deflate, more than `maxBytes`
/// once inflated, JSON that is not `{v: 1, url: http(s) string, jsonld:
/// [string, ...]}`, or no string blocks. A non-string block is dropped, not
/// fatal, as on Safari's path. One refusal is this build's own: an address
/// `URL` cannot hold is refused too, because `SharedRecipePage` keeps a `URL`.
///
/// Compiled into the app and the widget (it is in `Sources/Shared`), so it
/// uses Foundation, Apple's `Compression` and `LiftCore` only -- no network,
/// no SwiftData.
enum RecipeLink {

    static let prefix = "r1"
    /// The reference's `MAX_BYTES`: the most the JSON may inflate to. A real
    /// page's link is a few kilobytes (BBC Good Food 3.0 KB, Allrecipes 8.3 KB).
    static let maxBytes = 512 * 1024

    /// The host the bookmarklet's `liftApp` target opens:
    /// `dugcanliftlift://recipe#r1...`. A plan is `dugcanliftlift://plan#1z...`
    /// (`PlanLinkExtractor.urlHost`), so the host alone says which it is.
    static let urlHost = "recipe"

    /// True for LIFT's own scheme with the `recipe` host -- the only way a
    /// recipe link opens LIFT. Everything else under the scheme is the plan
    /// intake's, exactly as before recipe links existed.
    static func isRecipeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == PlanLinkExtractor.urlScheme
            && url.host()?.lowercased() == urlHost
    }

    /// The page an `r1` link carries, or nil. `text` is the whole link or its
    /// fragment; as in the reference, everything up to the first `#` is set
    /// aside, and with no `#` the text itself is the fragment.
    static func decode(_ text: String) -> SharedRecipePage? {
        let fragment: Substring
        if let hash = text.firstIndex(of: "#") {
            fragment = text[text.index(after: hash)...]
        } else {
            fragment = Substring(text)
        }
        guard fragment.hasPrefix(prefix) else { return nil }
        let data = fragment.dropFirst(prefix.count)
        guard !data.isEmpty, data.allSatisfy(isBase64URLCharacter) else { return nil }

        guard let deflated = base64URLDecoded(String(data)),
              let inflated = inflateRaw(deflated, limit: maxBytes)
        else { return nil }

        // Invalid UTF-8 becomes U+FFFD, as Node's `toString('utf8')` does.
        let json = String(decoding: inflated, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]),
              let doc = object as? [String: Any],
              isOne(doc["v"]),
              let address = doc["url"] as? String,
              let entries = doc["jsonld"] as? [Any]
        else { return nil }
        guard address.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: address)
        else { return nil }
        let blocks = entries.compactMap { $0 as? String }
        guard !blocks.isEmpty else { return nil }
        return SharedRecipePage(url: url, blocks: blocks)
    }

    // MARK: - Unwrapping

    /// `v === 1` in JavaScript: the number one, never `true` (which
    /// `JSONSerialization` also hands back as an `NSNumber`) and never `"1"`.
    private static func isOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return false }
        return number.doubleValue == 1
    }

    private static func isBase64URLCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// Unpadded base64url to bytes. A length that leaves one character over is
    /// not base64 at all, and is refused.
    private static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 2: base64 += "=="
        case 3: base64 += "="
        default: return nil
        }
        return Data(base64Encoded: base64)
    }

    /// Raw deflate (RFC 1951, what `CompressionStream('deflate-raw')` writes)
    /// to bytes. `COMPRESSION_ZLIB` is raw deflate, with no zlib header. Nil on
    /// a stream that is malformed, that ends before its final block, or that
    /// would inflate past `limit` -- which stops reading as soon as it is
    /// crossed, so a small link cannot make a large allocation.
    static func inflateRaw(_ input: Data, limit: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        let chunk = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPointer.pointee.src_ptr = source
            streamPointer.pointee.src_size = input.count

            var output = Data()
            while true {
                let unread = streamPointer.pointee.src_size
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPointer.pointee.dst_size
                if output.count + produced > limit { return nil }
                output.append(destination, count: produced)
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // Nothing read and nothing written, and no end of stream:
                    // the deflate was cut short.
                    if produced == 0 && streamPointer.pointee.src_size == unread { return nil }
                default:
                    return nil
                }
            }
        }
    }
}

/// Which of LIFT's two kinds of link opened the app, decided before either
/// decoder runs, so a plan link and a recipe link can never be read as each
/// other. A value type with no view in it, for the reason `PlanLinkIntake` is
/// one: `LiftApp.onOpenURL` only acts on the answer.
enum IncomingLink: Equatable {
    /// A recipe to open for review, exactly as a Safari share queues one.
    case recipe(PendingRecipeImports.Item)
    /// Everything else: a plan, a refusal (a recipe link that could not be
    /// read is one), or a link that was never LIFT's.
    case report(PlanLinkIntake.Outcome)

    static func open(_ url: URL, expectedLifterID: String) -> IncomingLink {
        guard RecipeLink.isRecipeURL(url) else {
            return .report(PlanLinkIntake.open(url, expectedLifterID: expectedLifterID))
        }
        // The first recipe in the page, the block that held it queued raw --
        // the rule `RecipeShareDecision` follows for Safari.
        guard let page = RecipeLink.decode(url.absoluteString) else {
            return .report(.refused(.unreadableRecipeLink))
        }
        guard let found = page.firstRecipe() else { return .report(.refused(.noRecipeInLink)) }
        return .recipe(.init(block: found.block, pageURL: page.url.absoluteString))
    }
}
