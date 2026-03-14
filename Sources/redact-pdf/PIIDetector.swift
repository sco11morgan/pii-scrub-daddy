import Foundation
import NaturalLanguage

struct PIIMatch {
    let range: Range<String.Index>
    let type: PIIType
}

enum PIIType: String {
    case ssn = "SSN"
    case phone = "Phone"
    case email = "Email"
    case creditCard = "CreditCard"
    case zipCode = "ZipCode"
    case person = "Person"
    case address = "Address"

    static let defaults: Set<PIIType> = [.ssn, .phone, .email, .creditCard]
    static let all: Set<PIIType>      = [.ssn, .phone, .email, .creditCard, .zipCode, .person, .address]
}

struct PIIDetector {
    // Regex patterns keyed by type
    private static let patterns: [(PIIType, String)] = [
        (.ssn,        #"\b\d{3}-\d{2}-\d{4}\b"#),
        (.ssn,        #"\b\d{9}\b"#),
        (.phone,      #"\b(\+1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b"#),
        (.email,      #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        (.creditCard, #"\b(?:\d{4}[\s\-]){3}\d{4}\b"#),
        (.zipCode,    #"\b\d{5}(?:-\d{4})?\b"#),
    ]

    static func detect(in text: String, types: Set<PIIType> = PIIType.defaults) -> [PIIMatch] {
        var matches: [PIIMatch] = []

        // Regex-based detection
        for (type, pattern) in patterns {
            guard types.contains(type) else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            for result in regex.matches(in: text, range: nsRange) {
                if let range = Range(result.range, in: text) {
                    matches.append(PIIMatch(range: range, type: type))
                }
            }
        }

        // NaturalLanguage named entity detection
        let wantPerson  = types.contains(.person)
        let wantAddress = types.contains(.address)
        if wantPerson || wantAddress {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
                if let tag = tag {
                    if wantPerson && tag == .personalName {
                        matches.append(PIIMatch(range: tokenRange, type: .person))
                    } else if wantAddress && (tag == .placeName || tag == .organizationName) {
                        matches.append(PIIMatch(range: tokenRange, type: .address))
                    }
                }
                return true
            }
        }

        return matches
    }
}
