import Foundation

/// SHA3-256（Keccak-f[1600]），与站点 CryptoJS `SHA3(e, {outputLength:256})` 一致。
/// 用于登录密码哈希；CryptoKit 不含 SHA3，且不想为此引入 SPM 依赖。
enum SHA3 {
    private static let rate = 136 // 1088 bits / 8
    private static let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    /// r[x][y]，x 为列、y 为行
    private static let rotation: [[Int]] = [
        [0, 1, 62, 28, 27],
        [36, 44, 6, 55, 20],
        [3, 10, 43, 25, 39],
        [41, 45, 15, 21, 8],
        [18, 2, 61, 56, 14],
    ]

    static func sha256Hex(_ text: String) -> String {
        var bytes = Array(text.utf8)
        bytes.append(0x06) // SHA3 domain separator（Keccak 用 0x01）
        while bytes.count % rate != rate - 1 { bytes.append(0) }
        bytes.append(0x80)

        var state = [UInt64](repeating: 0, count: 25)
        var offset = 0
        while offset < bytes.count {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for j in 0..<8 {
                    lane |= UInt64(bytes[offset + i * 8 + j]) << UInt64(8 * j)
                }
                state[i] ^= lane
            }
            permute(&state)
            offset += rate
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for i in 0..<4 {
            for j in 0..<8 {
                output.append(UInt8((state[i] >> UInt64(8 * j)) & 0xff))
            }
        }
        return output.map { String(format: "%02x", $0) }.joined()
    }

    private static func rotl(_ value: UInt64, _ amount: Int) -> UInt64 {
        guard amount != 0 else { return value }
        return (value << UInt64(amount)) | (value >> UInt64(64 - amount))
    }

    private static func permute(_ state: inout [UInt64]) {
        for round in 0..<24 {
            // θ
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                for y in 0..<5 { c[x] ^= state[x + 5 * y] }
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 { state[x + 5 * y] ^= d[x] }
            }

            // ρ + π
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], rotation[y][x])
                }
            }

            // χ
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y]
                        ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }

            // ι
            state[0] ^= rc[round]
        }
    }
}
