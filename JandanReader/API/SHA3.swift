import Foundation

/// 站点登录用的「SHA3-256」实为 **Keccak-256**（CryptoJS 版 SHA3）。
///
/// 证据（2026-11-26 抓站点 Nuxt bundle）：
/// - 登录页 chunk `LDv1WFtq.js` 用 `D(W.value)` 处理密码；
/// - `C1RStTSn.js` 末尾导出 `B(e)=z.default.SHA3(e,{outputLength:256}).toString(Hex)`；
/// - 打包的 crypto-js `SHA3._doFinalize` 只在消息后追加 `0x01` 位并在块尾追加 `0x80`，
///   **没有 FIPS 202 的 0x06 domain separator**，即旧 Keccak padding。
/// 因此之前的 FIPS 202 实现（0x06）与站点校验结果必然不同，密码登录恒失败。
///
/// 本实现与 `CryptoJS.SHA3(text,{outputLength:256})` 逐字节一致：
/// 空串 = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470；
/// "abc" = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45。
/// CryptoKit 不含 Keccak，且不想为此引入 SPM 依赖，故自带实现。
enum SHA3 {
    private static let rate = 136 // (1600 - 2 * 256) / 8
    private static let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    /// 表按 y 外层 / x 内层存放，取值 rotation[y][x] 即标准 r[x][y]。
    private static let rotation: [[Int]] = [
        [0, 1, 62, 28, 27],
        [36, 44, 6, 55, 20],
        [3, 10, 43, 25, 39],
        [41, 45, 15, 21, 8],
        [18, 2, 61, 56, 14],
    ]

    static func sha256Hex(_ text: String) -> String {
        var bytes = Array(text.utf8)
        // Keccak pad10*1：消息后追加 0x01，补零到 rate-1，最后追加 0x80。
        // 若消息占满 rate-1 字节，只剩 1 字节空间，起始位与结束位必须合并成
        // 单字节 0x81；分开写会多吸收一整块，长输入哈希全错。
        if bytes.count % rate == rate - 1 {
            bytes.append(0x81) // 0x01 | 0x80
        } else {
            bytes.append(0x01)
            while bytes.count % rate != rate - 1 { bytes.append(0) }
            bytes.append(0x80)
        }

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
