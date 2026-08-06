import XCTest
@testable import AI

final class ResponseURLTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // Black Forest Labs documents that the global endpoint returns a polling_url
    // on a regional cluster and that you must follow it. An exact-host check
    // would break every BFL image generation.
    func testBFLRegionalClusterIsAccepted() {
        let base = url("https://api.bfl.ai/v1")
        for regional in ["https://api.eu.bfl.ai/v1/get_result?id=1",
                         "https://api.us.bfl.ai/v1/get_result?id=1",
                         "https://api.bfl.ai/v1/get_result?id=1"] {
            XCTAssertTrue(
                ResponseURL.carriesCredentials(url(regional), matching: base),
                "\(regional) is a documented BFL endpoint"
            )
        }
    }

    func testGladiaResultURLIsAccepted() {
        XCTAssertTrue(ResponseURL.carriesCredentials(
            url("https://api.gladia.io/v2/transcription/abc"),
            matching: url("https://api.gladia.io")
        ))
    }

    func testGeminiFileURIIsAccepted() {
        XCTAssertTrue(ResponseURL.carriesCredentials(
            url("https://generativelanguage.googleapis.com/v1beta/files/abc:download"),
            matching: url("https://generativelanguage.googleapis.com/v1beta")
        ))
    }

    func testUnrelatedHostIsRefused() {
        for hostile in ["https://evil.tld/x",
                        "https://api.bfl.ai.evil.tld/x",
                        "https://notbfl.ai/x"] {
            XCTAssertFalse(
                ResponseURL.carriesCredentials(url(hostile), matching: url("https://api.bfl.ai/v1")),
                "\(hostile) must not receive the API key"
            )
        }
    }

    func testCleartextIsRefusedForRemoteHosts() {
        XCTAssertFalse(ResponseURL.carriesCredentials(
            url("http://api.bfl.ai/v1/get_result"), matching: url("https://api.bfl.ai/v1")
        ))
    }

    func testLoopbackOverHTTPIsAllowedOnlyAgainstALoopbackBase() {
        XCTAssertTrue(ResponseURL.carriesCredentials(
            url("http://localhost:8080/x"), matching: url("http://localhost:8080")
        ))
        XCTAssertFalse(ResponseURL.carriesCredentials(
            url("http://localhost:8080/x"), matching: url("https://api.bfl.ai/v1")
        ))
    }

    func testRegistrableDomainHandlesShortAndLongHosts() {
        XCTAssertEqual(ResponseURL.registrableDomain("api.eu.bfl.ai"), "bfl.ai")
        XCTAssertEqual(ResponseURL.registrableDomain("bfl.ai"), "bfl.ai")
        XCTAssertEqual(ResponseURL.registrableDomain("localhost"), "localhost")
    }
}
