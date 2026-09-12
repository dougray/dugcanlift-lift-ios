import CoreGraphics
import Foundation
import SwiftUI

/// Renders a string as a QR code.
///
/// The Task 6 brief called for `CIFilter.qrCodeGenerator()` via
/// `import CoreImage`. That does not compile on this SDK: watchOS (both the
/// device and simulator SDKs shipped with this Xcode) ships no `CoreImage`
/// framework at all -- there is no `CoreImage.framework`, no module map, and
/// no `CIFilter`/`qrCodeGenerator` symbol anywhere in the SDK. The brief's
/// premise ("available on watchOS with no entitlement") does not hold here.
///
/// This is a from-scratch QR encoder (ISO/IEC 18004), using only
/// `CoreGraphics` and `Foundation`, both of which are present on watchOS.
/// It always uses error-correction level M (matching what the brief asked
/// CIFilter for) and a fixed data-mask pattern (0) -- masking only affects
/// visual scan robustness, not correctness, so searching all 8 candidate
/// masks for the lowest penalty score was skipped as unnecessary complexity
/// for a code rendered cleanly on a watch screen rather than photographed at
/// an angle. The encode/matrix-placement logic was validated independently
/// (see the task report) by decoding generated codes with Vision's
/// `VNDetectBarcodesRequest` across payload sizes from 2 bytes to 2 KB,
/// spanning every QR version boundary relevant to `StandaloneExport`'s
/// ~800-byte chunks.
enum QRCodeImage {
    static func make(from string: String) -> UIImage? {
        guard let matrix = try? QRCode.encode(text: string) else { return nil }
        // 3, not 8: verified codes still decode after downscaling to 220 px,
        // and the watch displays them around 368 px -- 8 was ~2.4x more
        // bitmap than any of that needs (18.7 MB vs ~2.6 MB across a typical
        // export's worth of pages).
        guard let cgImage = QRCode.renderCGImage(matrix: matrix, moduleScale: 3, quietZone: 4) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private enum QRCode {

    // MARK: GF(256) arithmetic (ISO/IEC 18004 primitive polynomial 0x11D)

    enum GF256 {
        static let exp: [Int] = {
            var t = [Int](repeating: 0, count: 512)
            var x = 1
            for i in 0..<255 {
                t[i] = x
                x <<= 1
                if x & 0x100 != 0 { x ^= 0x11D }
            }
            for i in 255..<512 { t[i] = t[i - 255] }
            return t
        }()
        static let log: [Int] = {
            var t = [Int](repeating: 0, count: 256)
            for i in 0..<255 { t[exp[i]] = i }
            return t
        }()
        static func mul(_ a: Int, _ b: Int) -> Int {
            if a == 0 || b == 0 { return 0 }
            return exp[log[a] + log[b]]
        }
    }

    static func polyMultiply(_ a: [Int], _ b: [Int]) -> [Int] {
        var result = [Int](repeating: 0, count: a.count + b.count - 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                result[i + j] ^= GF256.mul(a[i], b[j])
            }
        }
        return result
    }

    static func generatorPolynomial(degree: Int) -> [Int] {
        var g: [Int] = [1]
        for i in 0..<degree {
            g = polyMultiply(g, [1, GF256.exp[i]])
        }
        return g
    }

    /// Systematic Reed-Solomon encode: the remainder of message(x)*x^degree
    /// divided by the generator polynomial, computed over GF(256).
    static func computeECC(message: [UInt8], generator: [Int]) -> [UInt8] {
        var remainder = message.map { Int($0) } + [Int](repeating: 0, count: generator.count - 1)
        for i in 0..<message.count {
            let coef = remainder[i]
            if coef != 0 {
                for j in 0..<generator.count {
                    remainder[i + j] ^= GF256.mul(generator[j], coef)
                }
            }
        }
        return remainder[message.count...].map { UInt8($0) }
    }

    // MARK: Tables (ECC level M only -- the level the brief asked CIFilter for)

    struct ECBlockInfo {
        let ecCodewordsPerBlock: Int
        let group1Blocks: Int
        let group1DataCodewords: Int
        let group2Blocks: Int
        let group2DataCodewords: Int
        var totalDataCodewords: Int { group1Blocks * group1DataCodewords + group2Blocks * group2DataCodewords }
    }

    /// Index 0 = version 1. Values from the ISO/IEC 18004 error-correction
    /// block table, level M.
    static let eccTableM: [ECBlockInfo] = [
        .init(ecCodewordsPerBlock: 10, group1Blocks: 1, group1DataCodewords: 16, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 16, group1Blocks: 1, group1DataCodewords: 28, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 1, group1DataCodewords: 44, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 18, group1Blocks: 2, group1DataCodewords: 32, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 24, group1Blocks: 2, group1DataCodewords: 43, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 16, group1Blocks: 4, group1DataCodewords: 27, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 18, group1Blocks: 4, group1DataCodewords: 31, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 22, group1Blocks: 2, group1DataCodewords: 38, group2Blocks: 2, group2DataCodewords: 39),
        .init(ecCodewordsPerBlock: 22, group1Blocks: 3, group1DataCodewords: 36, group2Blocks: 2, group2DataCodewords: 37),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 4, group1DataCodewords: 43, group2Blocks: 1, group2DataCodewords: 44),
        .init(ecCodewordsPerBlock: 30, group1Blocks: 1, group1DataCodewords: 50, group2Blocks: 4, group2DataCodewords: 51),
        .init(ecCodewordsPerBlock: 22, group1Blocks: 6, group1DataCodewords: 36, group2Blocks: 2, group2DataCodewords: 37),
        .init(ecCodewordsPerBlock: 22, group1Blocks: 8, group1DataCodewords: 37, group2Blocks: 1, group2DataCodewords: 38),
        .init(ecCodewordsPerBlock: 24, group1Blocks: 4, group1DataCodewords: 40, group2Blocks: 5, group2DataCodewords: 41),
        .init(ecCodewordsPerBlock: 24, group1Blocks: 5, group1DataCodewords: 41, group2Blocks: 5, group2DataCodewords: 42),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 7, group1DataCodewords: 45, group2Blocks: 3, group2DataCodewords: 46),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 10, group1DataCodewords: 46, group2Blocks: 1, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 9, group1DataCodewords: 43, group2Blocks: 4, group2DataCodewords: 44),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 3, group1DataCodewords: 44, group2Blocks: 11, group2DataCodewords: 45),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 3, group1DataCodewords: 41, group2Blocks: 13, group2DataCodewords: 42),
        .init(ecCodewordsPerBlock: 26, group1Blocks: 17, group1DataCodewords: 42, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 17, group1DataCodewords: 46, group2Blocks: 0, group2DataCodewords: 0),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 4, group1DataCodewords: 47, group2Blocks: 14, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 6, group1DataCodewords: 45, group2Blocks: 14, group2DataCodewords: 46),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 8, group1DataCodewords: 47, group2Blocks: 13, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 19, group1DataCodewords: 46, group2Blocks: 4, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 22, group1DataCodewords: 45, group2Blocks: 3, group2DataCodewords: 46),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 3, group1DataCodewords: 45, group2Blocks: 23, group2DataCodewords: 46),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 21, group1DataCodewords: 45, group2Blocks: 7, group2DataCodewords: 46),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 19, group1DataCodewords: 47, group2Blocks: 10, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 2, group1DataCodewords: 46, group2Blocks: 29, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 10, group1DataCodewords: 46, group2Blocks: 23, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 14, group1DataCodewords: 46, group2Blocks: 21, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 14, group1DataCodewords: 46, group2Blocks: 23, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 12, group1DataCodewords: 47, group2Blocks: 26, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 6, group1DataCodewords: 47, group2Blocks: 34, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 29, group1DataCodewords: 46, group2Blocks: 14, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 13, group1DataCodewords: 46, group2Blocks: 32, group2DataCodewords: 47),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 40, group1DataCodewords: 47, group2Blocks: 7, group2DataCodewords: 48),
        .init(ecCodewordsPerBlock: 28, group1Blocks: 18, group1DataCodewords: 47, group2Blocks: 31, group2DataCodewords: 48),
    ]

    static let alignmentTable: [Int: [Int]] = [
        2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
        7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
        11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62],
        14: [6, 26, 46, 66], 15: [6, 26, 48, 70], 16: [6, 26, 50, 74],
        17: [6, 30, 54, 78], 18: [6, 30, 56, 82], 19: [6, 30, 58, 86], 20: [6, 34, 62, 90],
        21: [6, 28, 50, 72, 94], 22: [6, 26, 50, 74, 98], 23: [6, 30, 54, 78, 102],
        24: [6, 28, 54, 80, 106], 25: [6, 32, 58, 84, 110], 26: [6, 30, 58, 86, 114], 27: [6, 34, 62, 90, 118],
        28: [6, 26, 50, 74, 98, 122], 29: [6, 30, 54, 78, 102, 126], 30: [6, 26, 52, 78, 104, 130],
        31: [6, 30, 56, 82, 108, 134], 32: [6, 34, 60, 86, 112, 138], 33: [6, 30, 58, 86, 114, 142],
        34: [6, 34, 62, 90, 118, 146],
        35: [6, 30, 54, 78, 102, 126, 150], 36: [6, 24, 50, 76, 102, 128, 154],
        37: [6, 28, 54, 80, 106, 132, 158], 38: [6, 32, 58, 84, 110, 136, 162],
        39: [6, 26, 54, 82, 110, 138, 166], 40: [6, 30, 58, 86, 114, 142, 170],
    ]

    /// ECC level M format strings, index = mask pattern 0...7. Each string is
    /// the final 15-bit value (BCH-encoded data already XORed with the
    /// standard's fixed format mask), ready to place directly.
    static let formatStringsM: [String] = [
        "101010000010010", "101000100100101", "101111001111100", "101101101001011",
        "100010111111001", "100000011001110", "100111110010111", "100101010100000",
    ]

    /// Version info strings for versions 7...40 (18-bit BCH codes).
    static let versionInfoStrings: [String] = [
        "000111110010010100", "001000010110111100", "001001101010011001", "001010010011010011",
        "001011101111110110", "001100011101100010", "001101100001000111", "001110011000001101",
        "001111100100101000",
        "010000101101111000", "010001010001011101", "010010101000010111", "010011010100110010",
        "010100100110100110", "010101011010000011", "010110100011001001", "010111011111101100",
        "011000111011000100",
        "011001000111100001", "011010111110101011", "011011000010001110", "011100110000011010",
        "011101001100111111", "011110110101110101", "011111001001010000", "100000100111010101",
        "100001011011110000", "100010100010111010", "100011011110011111", "100100101100001011",
        "100101010000101110", "100110101001100100", "100111010101000001", "101000110001101001",
    ]

    // MARK: Bit writer

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bitBuffer: UInt8 = 0
        private var bitCount: Int = 0

        mutating func appendBits(_ value: Int, _ length: Int) {
            guard length > 0 else { return }
            for i in stride(from: length - 1, through: 0, by: -1) {
                let bit = (value >> i) & 1
                bitBuffer = (bitBuffer << 1) | UInt8(bit)
                bitCount += 1
                if bitCount == 8 {
                    bytes.append(bitBuffer)
                    bitBuffer = 0
                    bitCount = 0
                }
            }
        }

        var bitLength: Int { bytes.count * 8 + bitCount }

        mutating func padToByte() {
            if bitCount > 0 {
                bitBuffer <<= (8 - bitCount)
                bytes.append(bitBuffer)
                bitBuffer = 0
                bitCount = 0
            }
        }

        mutating func padWithAlternating(to targetByteCount: Int) {
            var toggle = true
            while bytes.count < targetByteCount {
                bytes.append(toggle ? 0xEC : 0x11)
                toggle.toggle()
            }
        }
    }

    enum EncodeError: Error { case dataTooLarge }

    static func chooseVersion(dataByteCount: Int) throws -> (version: Int, info: ECBlockInfo) {
        for version in 1...40 {
            let info = eccTableM[version - 1]
            let countBits = version <= 9 ? 8 : 16
            let neededBits = 4 + countBits + dataByteCount * 8
            if neededBits <= info.totalDataCodewords * 8 {
                return (version, info)
            }
        }
        throw EncodeError.dataTooLarge
    }

    static func buildCodewords(dataBytes: [UInt8], version: Int, info: ECBlockInfo) -> [UInt8] {
        var bw = BitWriter()
        bw.appendBits(0b0100, 4) // byte mode
        let countBits = version <= 9 ? 8 : 16
        bw.appendBits(dataBytes.count, countBits)
        for byte in dataBytes { bw.appendBits(Int(byte), 8) }

        let capacityBits = info.totalDataCodewords * 8
        let terminatorLen = max(0, min(4, capacityBits - bw.bitLength))
        if terminatorLen > 0 { bw.appendBits(0, terminatorLen) }
        bw.padToByte()

        bw.padWithAlternating(to: info.totalDataCodewords)
        return bw.bytes
    }

    static func interleave(dataCodewords: [UInt8], info: ECBlockInfo) -> [UInt8] {
        var blocks: [[UInt8]] = []
        var offset = 0
        for _ in 0..<info.group1Blocks {
            blocks.append(Array(dataCodewords[offset..<offset + info.group1DataCodewords]))
            offset += info.group1DataCodewords
        }
        for _ in 0..<info.group2Blocks {
            blocks.append(Array(dataCodewords[offset..<offset + info.group2DataCodewords]))
            offset += info.group2DataCodewords
        }

        let generator = generatorPolynomial(degree: info.ecCodewordsPerBlock)
        let eccBlocks = blocks.map { computeECC(message: $0, generator: generator) }

        var interleavedData: [UInt8] = []
        let maxLen = blocks.map { $0.count }.max() ?? 0
        for i in 0..<maxLen {
            for block in blocks where i < block.count {
                interleavedData.append(block[i])
            }
        }
        var interleavedEC: [UInt8] = []
        for i in 0..<info.ecCodewordsPerBlock {
            for eccBlock in eccBlocks {
                interleavedEC.append(eccBlock[i])
            }
        }
        return interleavedData + interleavedEC
    }

    final class MatrixBuilder {
        let version: Int
        let size: Int
        var grid: [[Bool]]
        var isFunction: [[Bool]]

        init(version: Int) {
            self.version = version
            self.size = version * 4 + 17
            self.grid = Array(repeating: Array(repeating: false, count: size), count: size)
            self.isFunction = Array(repeating: Array(repeating: false, count: size), count: size)
        }

        func setModule(_ r: Int, _ c: Int, _ dark: Bool) {
            guard r >= 0, r < size, c >= 0, c < size else { return }
            grid[r][c] = dark
            isFunction[r][c] = true
        }

        func drawFinder(_ centerRow: Int, _ centerCol: Int) {
            for dr in -4...4 {
                for dc in -4...4 {
                    let r = centerRow + dr, c = centerCol + dc
                    guard r >= 0, r < size, c >= 0, c < size else { continue }
                    let dist = max(abs(dr), abs(dc))
                    setModule(r, c, dist <= 1 || dist == 3)
                }
            }
        }

        func drawAlignment(_ centerRow: Int, _ centerCol: Int) {
            for dr in -2...2 {
                for dc in -2...2 {
                    let dist = max(abs(dr), abs(dc))
                    setModule(centerRow + dr, centerCol + dc, dist != 1)
                }
            }
        }

        func drawTiming() {
            for i in 8..<(size - 8) {
                if !isFunction[6][i] { setModule(6, i, i % 2 == 0) }
                if !isFunction[i][6] { setModule(i, 6, i % 2 == 0) }
            }
        }

        func drawFunctionPatterns() {
            drawFinder(3, 3)
            drawFinder(3, size - 4)
            drawFinder(size - 4, 3)

            if let coords = alignmentTable[version] {
                let first = coords.first!, last = coords.last!
                for r in coords {
                    for c in coords {
                        if (r == first && c == first) || (r == first && c == last) || (r == last && c == first) {
                            continue
                        }
                        drawAlignment(r, c)
                    }
                }
            }
            drawTiming()
        }

        /// Bit-to-coordinate order verified empirically against a reference
        /// QR implementation by generating the same payload across all 8
        /// masks and matching each candidate cell's value pattern against
        /// the known per-bit value pattern from `formatStringsM` (see the
        /// task report for the derivation).
        func writeFormatInfo(maskPattern: Int) {
            let bitsStr = formatStringsM[maskPattern]
            let bits = bitsStr.map { $0 == "1" }

            // Copy A: (8,0)->(8,8) [bits 0-7] then (7,8)->(0,8) [bits 7-14, corner shared]
            let orderA: [(Int, Int)] = [(8,0),(8,1),(8,2),(8,3),(8,4),(8,5),(8,7),(8,8),
                                         (7,8),(5,8),(4,8),(3,8),(2,8),(1,8),(0,8)]
            for (i, (r, c)) in orderA.enumerated() { setModule(r, c, bits[i]) }

            // Copy B: (size-1,8)->(size-7,8) [bits 0-6] then (8,size-8)->(8,size-1) [bits 7-14]
            let orderB: [(Int, Int)] = [(size-1,8),(size-2,8),(size-3,8),(size-4,8),(size-5,8),(size-6,8),(size-7,8),
                                         (8,size-8),(8,size-7),(8,size-6),(8,size-5),(8,size-4),(8,size-3),(8,size-2),(8,size-1)]
            for (i, (r, c)) in orderB.enumerated() { setModule(r, c, bits[i]) }

            // Always-dark module.
            setModule(size - 8, 8, true)
        }

        /// Same empirical derivation as `writeFormatInfo`: the natural
        /// column-major (bottom-left) / row-major (top-right) fill order is
        /// the reverse of bit order -- bit 17 (the LSB) fills first.
        func writeVersionInfo() {
            guard version >= 7 else { return }
            let bitsStr = versionInfoStrings[version - 7]
            let bits = bitsStr.map { $0 == "1" }

            for colInBlock in 0..<6 {
                for rowInBlock in 0..<3 {
                    let bitIndex = 17 - (colInBlock * 3 + rowInBlock)
                    setModule(size - 11 + rowInBlock, colInBlock, bits[bitIndex])
                }
            }
            for rowInBlock in 0..<6 {
                for colInBlock in 0..<3 {
                    let bitIndex = 17 - (rowInBlock * 3 + colInBlock)
                    setModule(rowInBlock, size - 11 + colInBlock, bits[bitIndex])
                }
            }
        }

        /// The standard "two columns at a time, snake pattern" data
        /// placement: walk column pairs from the right edge, alternating
        /// direction each pair, skipping the vertical timing column and any
        /// module already claimed by a function pattern.
        func placeData(bits: [Bool], maskPattern: Int) {
            func maskFor(_ row: Int, _ col: Int) -> Bool {
                switch maskPattern {
                case 0: return (row + col) % 2 == 0
                case 1: return row % 2 == 0
                case 2: return col % 3 == 0
                case 3: return (row + col) % 3 == 0
                case 4: return ((row / 2) + (col / 3)) % 2 == 0
                case 5: return (row * col) % 2 + (row * col) % 3 == 0
                case 6: return ((row * col) % 2 + (row * col) % 3) % 2 == 0
                default: return ((row + col) % 2 + (row * col) % 3) % 2 == 0
                }
            }

            var bitIndex = 0
            var col = size - 1
            var upward = true
            while col > 0 {
                if col == 6 { col -= 1 }
                let rows = upward ? Array(stride(from: size - 1, through: 0, by: -1)) : Array(0..<size)
                for row in rows {
                    for c in [col, col - 1] {
                        guard !isFunction[row][c] else { continue }
                        var bit = bitIndex < bits.count ? bits[bitIndex] : false
                        bitIndex += 1
                        if maskFor(row, c) { bit.toggle() }
                        grid[row][c] = bit
                    }
                }
                upward.toggle()
                col -= 2
            }
        }
    }

    static func encode(text: String) throws -> [[Bool]] {
        let dataBytes = Array(text.utf8)
        let (version, info) = try chooseVersion(dataByteCount: dataBytes.count)
        let dataCodewords = buildCodewords(dataBytes: dataBytes, version: version, info: info)
        let allCodewords = interleave(dataCodewords: dataCodewords, info: info)

        var dataBits: [Bool] = []
        dataBits.reserveCapacity(allCodewords.count * 8)
        for byte in allCodewords {
            for i in stride(from: 7, through: 0, by: -1) {
                dataBits.append((byte >> i) & 1 == 1)
            }
        }

        let builder = MatrixBuilder(version: version)
        builder.drawFunctionPatterns()
        let maskPattern = 0
        builder.writeFormatInfo(maskPattern: maskPattern)
        builder.writeVersionInfo()
        builder.placeData(bits: dataBits, maskPattern: maskPattern)
        return builder.grid
    }

    static func renderCGImage(matrix: [[Bool]], moduleScale: Int, quietZone: Int) -> CGImage? {
        let size = matrix.count
        let totalModules = size + quietZone * 2
        let pixelSize = totalModules * moduleScale
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                       bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.setFillColor(gray: 0.0, alpha: 1.0)
        for row in 0..<size {
            for col in 0..<size where matrix[row][col] {
                // CGContext's origin is bottom-left; flip row so row 0 renders at the top.
                let x = (col + quietZone) * moduleScale
                let y = pixelSize - (row + quietZone + 1) * moduleScale
                context.fill(CGRect(x: x, y: y, width: moduleScale, height: moduleScale))
            }
        }
        return context.makeImage()
    }
}
