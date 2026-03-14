import XCTest
@testable import PIIScrubCore

final class PIIDetectorTests: XCTestCase {

    // MARK: - SSN

    func testSSNWithDashes() {
        let matches = PIIDetector.detect(in: "SSN: 123-45-6789.", types: [.ssn])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .ssn)
    }

    func testSSNNineConsecutiveDigits() {
        let matches = PIIDetector.detect(in: "SSN: 123456789.", types: [.ssn])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .ssn)
    }

    func testSSNNotMatchedInTenDigitRun() {
        // Word-boundary guards must prevent matching inside a longer digit string
        let matches = PIIDetector.detect(in: "1234567890", types: [.ssn])
        XCTAssertEqual(matches.count, 0)
    }

    func testSSNNotMatchedInEightDigitRun() {
        let matches = PIIDetector.detect(in: "12345678", types: [.ssn])
        XCTAssertEqual(matches.count, 0)
    }

    func testSSNNotReturnedWhenTypeExcluded() {
        let matches = PIIDetector.detect(in: "123-45-6789", types: [.phone])
        XCTAssertEqual(matches.count, 0)
    }

    // MARK: - Phone

    func testPhoneDashes() {
        let matches = PIIDetector.detect(in: "Call 555-867-5309 now.", types: [.phone])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .phone)
    }

    func testPhoneDots() {
        let matches = PIIDetector.detect(in: "555.867.5309", types: [.phone])
        XCTAssertEqual(matches.count, 1)
    }

    func testPhoneParens() {
        let matches = PIIDetector.detect(in: "(555) 867-5309", types: [.phone])
        XCTAssertEqual(matches.count, 1)
    }

    func testPhoneWithCountryCode() {
        let matches = PIIDetector.detect(in: "+1 555-867-5309", types: [.phone])
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Email

    func testEmailSimple() {
        let matches = PIIDetector.detect(in: "Contact user@example.com today.", types: [.email])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .email)
    }

    func testEmailWithSubdomainAndPlusTags() {
        let matches = PIIDetector.detect(in: "user.name+tag@subdomain.example.co.uk", types: [.email])
        XCTAssertEqual(matches.count, 1)
    }

    func testEmailNoFalsePositive() {
        let matches = PIIDetector.detect(in: "notanemail", types: [.email])
        XCTAssertEqual(matches.count, 0)
    }

    // MARK: - Credit Card

    func testCreditCardSpaces() {
        let matches = PIIDetector.detect(in: "Card: 4111 1111 1111 1111.", types: [.creditCard])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .creditCard)
    }

    func testCreditCardDashes() {
        let matches = PIIDetector.detect(in: "4111-1111-1111-1111", types: [.creditCard])
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Zip Code

    func testZipCodeFiveDigit() {
        let matches = PIIDetector.detect(in: "Pewaukee, WI 53072", types: [.zipCode])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].type, .zipCode)
    }

    func testZipCodePlusFour() {
        let matches = PIIDetector.detect(in: "12345-6789", types: [.zipCode])
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Defaults

    func testDefaultTypesExcludeZipPersonAddress() {
        let text = "Pewaukee, WI 53072 John Smith"
        let matches = PIIDetector.detect(in: text) // uses PIIType.defaults
        XCTAssertTrue(matches.allSatisfy { $0.type != .zipCode })
        XCTAssertTrue(matches.allSatisfy { $0.type != .person })
        XCTAssertTrue(matches.allSatisfy { $0.type != .address })
    }

    func testMultiplePIITypesDetectedInOneString() {
        let text = "SSN: 123-45-6789, Email: foo@bar.com, Phone: 555-123-4567"
        let matches = PIIDetector.detect(in: text)
        let types = Set(matches.map(\.type))
        XCTAssertTrue(types.contains(.ssn))
        XCTAssertTrue(types.contains(.email))
        XCTAssertTrue(types.contains(.phone))
    }

    func testEmptyStringReturnsNoMatches() {
        XCTAssertTrue(PIIDetector.detect(in: "").isEmpty)
    }
}
