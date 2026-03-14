import XCTest
import CoreGraphics
import ImageIO
@testable import PIIScrubCore

final class ImageRedactorTests: XCTestCase {

    private var tmpURLs: [URL] = []

    override func tearDown() {
        for url in tmpURLs { try? FileManager.default.removeItem(at: url) }
        tmpURLs = []
        super.tearDown()
    }

    private func tmpOutput(ext: String = "jpg") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        tmpURLs.append(url)
        return url
    }

    // MARK: - Fixture helpers

    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "Missing test fixture: \(name).\(ext)"
        )
    }

    // MARK: - Tests

    func testSocialSecurityCardIsRedacted() throws {
        let input  = try fixtureURL("socialsecurity", ext: "jpg")
        let output = tmpOutput()

        XCTAssertNoThrow(try ImageRedactor.redact(inputURL: input, outputURL: output, types: [.ssn]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // Output bytes must differ — at least some pixels were blacked out
        let inputData  = try Data(contentsOf: input)
        let outputData = try Data(contentsOf: output)
        XCTAssertNotEqual(inputData, outputData, "Redacted output should differ from the original image")
    }

    func testOutputPreservesOriginalDimensions() throws {
        let input  = try fixtureURL("socialsecurity", ext: "jpg")
        let output = tmpOutput()

        try ImageRedactor.redact(inputURL: input, outputURL: output, types: [.ssn])

        let inSrc  = try XCTUnwrap(CGImageSourceCreateWithURL(input  as CFURL, nil))
        let outSrc = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let inImg  = try XCTUnwrap(CGImageSourceCreateImageAtIndex(inSrc,  0, nil))
        let outImg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outSrc, 0, nil))

        XCTAssertEqual(inImg.width,  outImg.width,  "Width must be preserved after redaction")
        XCTAssertEqual(inImg.height, outImg.height, "Height must be preserved after redaction")
    }

    func testPNGOutputFormat() throws {
        let input  = try fixtureURL("socialsecurity", ext: "jpg")
        let output = tmpOutput(ext: "png")

        XCTAssertNoThrow(try ImageRedactor.redact(inputURL: input, outputURL: output, types: [.ssn]))

        // Verify PNG magic bytes: 89 50 4E 47
        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "Output should be valid PNG")
    }

    func testNonExistentInputThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/fake.jpg")
        let output  = tmpOutput()
        XCTAssertThrowsError(
            try ImageRedactor.redact(inputURL: missing, outputURL: output)
        )
    }

    func testSupportedExtensionsNotEmpty() {
        XCTAssertFalse(ImageRedactor.supportedExtensions.isEmpty)
        XCTAssertTrue(ImageRedactor.supportedExtensions.contains("jpg"))
        XCTAssertTrue(ImageRedactor.supportedExtensions.contains("png"))
        XCTAssertTrue(ImageRedactor.supportedExtensions.contains("pdf") == false)
    }
}
