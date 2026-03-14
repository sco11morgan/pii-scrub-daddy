import XCTest
import PDFKit
@testable import PIIScrubCore

final class PDFRedactorTests: XCTestCase {

    private var tmpURLs: [URL] = []

    override func tearDown() {
        for url in tmpURLs { try? FileManager.default.removeItem(at: url) }
        tmpURLs = []
        super.tearDown()
    }

    private func tmpOutput(ext: String = "pdf") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        tmpURLs.append(url)
        return url
    }

    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "Missing test fixture: \(name).\(ext)"
        )
    }

    // MARK: - Tests

    func testFormPDFProducesOutput() throws {
        let input  = try fixtureURL("f1040", ext: "pdf")
        let output = tmpOutput()

        XCTAssertNoThrow(try PDFRedactor.redact(inputURL: input, outputURL: output, types: [.ssn]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let data = try Data(contentsOf: output)
        XCTAssertFalse(data.isEmpty, "Redacted PDF should not be empty")
    }

    func testRedactedPDFIsValidPDF() throws {
        let input  = try fixtureURL("f1040", ext: "pdf")
        let output = tmpOutput()

        try PDFRedactor.redact(inputURL: input, outputURL: output, types: [.ssn])

        let doc = try XCTUnwrap(PDFDocument(url: output), "Output should be a readable PDF")
        XCTAssertGreaterThan(doc.pageCount, 0, "Redacted PDF should have at least one page")
    }

    func testRedactedPDFHasSamePageCountAsInput() throws {
        let input  = try fixtureURL("f1040", ext: "pdf")
        let output = tmpOutput()

        let inputDoc = try XCTUnwrap(PDFDocument(url: input))
        try PDFRedactor.redact(inputURL: input, outputURL: output, types: [.ssn])
        let outputDoc = try XCTUnwrap(PDFDocument(url: output))

        XCTAssertEqual(inputDoc.pageCount, outputDoc.pageCount, "Page count should be preserved")
    }

    func testRedactedPDFHasNoTextLayer() throws {
        // Output is a rasterized PDF — PDFKit should extract no text
        let input  = try fixtureURL("f1040", ext: "pdf")
        let output = tmpOutput()

        try PDFRedactor.redact(inputURL: input, outputURL: output, types: [.ssn])

        let doc = try XCTUnwrap(PDFDocument(url: output))
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string ?? ""
            XCTAssertTrue(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Redacted PDF page \(i + 1) should have no text layer"
            )
        }
    }

    func testNonExistentInputThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/fake.pdf")
        let output  = tmpOutput()
        XCTAssertThrowsError(
            try PDFRedactor.redact(inputURL: missing, outputURL: output)
        )
    }
}
