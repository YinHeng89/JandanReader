import XCTest
@testable import JandanReader

/// 纯逻辑回归测试：这些点都踩过坑，必须锁住。
/// 向量来自站点登录页实际调用的 `CryptoJS.SHA3(x,{outputLength:256})`（crypto-js 4.1.1）。
final class SHA3Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(
            SHA3.sha256Hex(""),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        )
        XCTAssertEqual(
            SHA3.sha256Hex("abc"),
            "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        )
    }

    /// 覆盖 rate(136) 的块边界，尤其是 ≡135 时 0x01|0x80 必须合并为 0x81。
    func testRateBoundaryVectors() {
        let vectors: [(Int, String)] = [
            (0, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"),
            (1, "3ac225168df54212a25c1c01fd35bebfea408fdac2e31ddd6f80a4bbf9a5f1cb"),
            (3, "b9a5dc0048db9a7d13548781df3cd4b2334606391f75f40c14225a92f4cb3537"),
            (6, "4a8d5e1b218e22b51509bf4d4f234a502c0a5af922ff73c5358ffa13f63d6d11"),
            (134, "e5de5653994e2fa6729d329b65b5f332dee942a7ea54515e173824c232a4ff91"),
            (135, "34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446"),
            (136, "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e"),
            (270, "cfecd7939f149ad981c5672b3a7c4fe8b584b6b3dbe899b2575c8a92e77f8f28"),
            (271, "132f47effd6c8b1b299efa53fe68aece77ec8ae4eb2e294f668eec94f76001e1"),
            (406, "c22dba8fa543d0ae16c1e6fde6580e24f61d37f41821d73c0641b5a178abd89e"),
        ]
        for (count, expected) in vectors {
            XCTAssertEqual(
                SHA3.sha256Hex(String(repeating: "a", count: count)),
                expected,
                "长度 \(count) 的向量不匹配"
            )
        }
    }
}

final class JDHTMLTests: XCTestCase {
    func testThumbnailSwitchActuallyChangesURL() {
        let large = URL(string: "https://img.toto.im/large/photo.jpg")!
        XCTAssertEqual(
            JDHTML.displayURL(large, thumbnail: true).absoluteString,
            "https://img.toto.im/mw600/photo.jpg"
        )
        XCTAssertEqual(
            JDHTML.displayURL(large, thumbnail: false).absoluteString,
            "https://img.toto.im/large/photo.jpg"
        )
    }

    func testSharingAlwaysUsesOriginal() {
        let thumb = URL(string: "https://img.toto.im/mw600/photo.jpg")!
        XCTAssertEqual(
            JDHTML.originalURL(thumb).absoluteString,
            "https://img.toto.im/large/photo.jpg"
        )
        let gif = URL(string: "https://img.toto.im/mw600/a.gif.webp")!
        XCTAssertEqual(
            JDHTML.originalURL(gif).absoluteString,
            "https://img.toto.im/large/a.gif"
        )
    }

    func testGIFDerivation() {
        let gif = URL(string: "https://img.toto.im/mw600/a.gif.webp")!
        XCTAssertTrue(JDHTML.isGIF(gif))
        XCTAssertEqual(JDHTML.staticGIFURL(gif)?.absoluteString, "https://img.toto.im/mw600/a.gif.webp")
        XCTAssertEqual(JDHTML.animatedGIFURL(gif)?.absoluteString, "https://img.toto.im/large/a.gif")
        XCTAssertEqual(JDHTML.animatedVideoURL(gif)?.absoluteString, "https://img.toto.im/large/a.mp4")
    }

    func testPlainDecodesEntitiesOnce() {
        XCTAssertEqual(JDHTML.plain("<p>A&nbsp;&amp;&lt;&gt;&quot;&#39;</p>"), "A &<>\"'")
        // 不能把已转义的实体再解码一次
        XCTAssertEqual(JDHTML.plain("&amp;#39;"), "&#39;")
    }

    func testBlocksKeepImageAndLinkOrder() {
        let html = "前<img src=\"https://a.com/1.jpg\">中<a href=\"https://jandan.net/p/1\">链接</a>后"
        let blocks = JDHTML.blocks(in: html)
        XCTAssertEqual(blocks.count, 5)
        if case .text(let value) = blocks[0] { XCTAssertEqual(value, "前") } else { XCTFail("第 1 块应为文字") }
        if case .image(let url) = blocks[1] {
            XCTAssertEqual(url.absoluteString, "https://a.com/1.jpg")
        } else { XCTFail("第 2 块应为图片") }
        if case .text(let value) = blocks[2] { XCTAssertEqual(value, "中") } else { XCTFail("第 3 块应为文字") }
        if case .link(let title, let url) = blocks[3] {
            XCTAssertEqual(title, "链接")
            XCTAssertEqual(url.absoluteString, "https://jandan.net/p/1")
        } else { XCTFail("第 4 块应为链接") }
        if case .text(let value) = blocks[4] { XCTAssertEqual(value, "后") } else { XCTFail("第 5 块应为文字") }
    }
}

final class JDAPITests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testSuccessEnvelopes() {
        XCTAssertNoThrow(try JDAPI.JDResponse.validate(data(#"{"code":0,"msg":"success","data":null}"#)))
        XCTAssertNoThrow(try JDAPI.JDResponse.validate(data(#"{"error":0,"msg":"ok"}"#)))
        // 裸值 / 数组不是错误信封（check_notice、时间线等接口）
        XCTAssertNoThrow(try JDAPI.JDResponse.validate(data("123")))
        XCTAssertNoThrow(try JDAPI.JDResponse.validate(data("[1,2]")))
    }

    func testBusinessFailuresAreNeverSilent() {
        XCTAssertThrowsError(try JDAPI.JDResponse.validate(data(#"{"code":403,"msg":"请登录煎蛋账号"}"#)))
        XCTAssertThrowsError(try JDAPI.JDResponse.validate(data(#"{"error":1,"msg":"您已经投过票"}"#)))
        XCTAssertThrowsError(try JDAPI.JDResponse.validate(data(#"{"error":"invalid token"}"#)))
        XCTAssertThrowsError(try JDAPI.JDResponse.validate(data(#"{"success":false,"msg":"失败"}"#)))
    }

    func testFormEncodingIsStrict() throws {
        let encoded = try JDAPI.encodeForm(["a b": "中文&x=1", "z": "a-b_c.*"])
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            "a+b=%E4%B8%AD%E6%96%87%26x%3D1&z=a-b_c.*"
        )
    }
}

final class JDLocalHelpersTests: XCTestCase {
    @MainActor
    func testPendingCommentEscaping() {
        XCTAssertEqual(
            JDPendingComment.escapedHTML("<b>&\""),
            "&lt;b&gt;&amp;&quot;"
        )
    }

    func testDateFormatters() {
        XCTAssertEqual("2026-11-26T10:06:55+08:00".jdSectionDate, "11月26日")
        XCTAssertEqual("2026-11-26 10:06:55".jdShortDate, "11-26 10:06")
    }
}
