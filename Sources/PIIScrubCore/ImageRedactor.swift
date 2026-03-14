import Foundation
import CoreGraphics
import Vision
import ImageIO
import UniformTypeIdentifiers

public struct ImageRedactor {

    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "webp"
    ]

    public static func redact(inputURL: URL, outputURL: URL, types: Set<PIIType> = PIIType.defaults, verbose: Bool = false) throws {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image  = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RedactError.cannotLoadImage(inputURL.path)
        }

        let pixelSize = CGSize(width: image.width, height: image.height)
        if verbose { print("  Image size: \(image.width) × \(image.height)") }

        let boxes = try ocrRedactionBoxes(image: image, pixelSize: pixelSize, types: types, verbose: verbose)

        // Draw original image then paint black boxes
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RedactError.renderFailed(0)
        }

        context.draw(image, in: CGRect(origin: .zero, size: pixelSize))

        if !boxes.isEmpty {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for box in boxes { context.fill(box) }
        }

        guard let finalImage = context.makeImage() else {
            throw RedactError.renderFailed(0)
        }

        try saveImage(finalImage, to: outputURL)
        if verbose { print("Saved redacted image to \(outputURL.path)") }
    }

    // MARK: - OCR

    private static func ocrRedactionBoxes(image: CGImage, pixelSize: CGSize, types: Set<PIIType>, verbose: Bool) throws -> [CGRect] {
        var boxes: [CGRect] = []
        let observations = try runOCR(on: image)

        // Collect (observation, candidate) pairs
        let pairs: [(obs: VNRecognizedTextObservation, text: VNRecognizedText)] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first else { return nil }
            return (obs, text)
        }

        if verbose {
            for (_, text) in pairs { print("  OCR: \"\(text.string)\"") }
        }

        // Pass 1 — detect PII within each observation's raw text
        for (obs, text) in pairs {
            for match in PIIDetector.detect(in: text.string, types: types) {
                if verbose { print("  Redacting [\(match.type.rawValue)]: \"\(text.string[match.range])\"") }
                let normBox = (try? text.boundingBox(for: match.range))?.boundingBox ?? obs.boundingBox
                boxes.append(visionToPixel(normBox, pixelSize: pixelSize))
            }
        }

        // Pass 2 — per-line normalized detection.
        // Groups observations that share the same horizontal line, then strips
        // whitespace within each line so spaced digits like "1 2 3 4 5 6 7 8 9"
        // in adjacent boxes are matched as "123456789".
        //
        // Grouping by line prevents digits from different sections of the page
        // (e.g. SSN field vs. Dependents table) from accidentally combining.

        struct CharInfo { let pairIndex: Int; let charIndex: String.Index }

        // Tag each pair with its original index before sorting, so we never
        // need a fragile identity lookup after the sort.
        struct IndexedPair {
            let origIndex: Int
            let obs: VNRecognizedTextObservation
            let text: VNRecognizedText
        }
        let indexed = pairs.enumerated().map { IndexedPair(origIndex: $0, obs: $1.obs, text: $1.text) }

        // Sort top-to-bottom (highest Vision y = top of page), left-to-right
        let sorted = indexed.sorted { a, b in
            let ay = a.obs.boundingBox.midY, by = b.obs.boundingBox.midY
            if abs(ay - by) > 0.015 { return ay > by }
            return a.obs.boundingBox.midX < b.obs.boundingBox.midX
        }

        // Group into lines: a new line starts when midY jumps by more than
        // ~2% of page height (≈15 px on an 800 px image).
        var lines: [[IndexedPair]] = []
        var currentLine: [IndexedPair] = []
        var lineAnchorY: CGFloat = -1

        for item in sorted {
            let y = item.obs.boundingBox.midY
            if currentLine.isEmpty || abs(y - lineAnchorY) <= 0.02 {
                if currentLine.isEmpty { lineAnchorY = y }
                currentLine.append(item)
            } else {
                lines.append(currentLine)
                currentLine = [item]
                lineAnchorY = y
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }

        // For each line, build a normalised string + charMap, then detect PII.
        // In addition to whitespace, strip "|" and box-drawing characters that
        // OCR commonly produces from table grid lines in scanned forms — these
        // appear between individual digit boxes and would otherwise break
        // runs of digits (e.g. "555144|3333" failing to match \d{9}).
        let ocrGridNoise: Set<Character> = ["|", "│", "║", "┃", "╎", "╏"]

        for line in lines {
            var normalizedText = ""
            var charMap: [CharInfo] = []

            for item in line {
                var idx = item.text.string.startIndex
                while idx < item.text.string.endIndex {
                    let c = item.text.string[idx]
                    if !c.isWhitespace && !ocrGridNoise.contains(c) {
                        normalizedText.append(c)
                        charMap.append(CharInfo(pairIndex: item.origIndex, charIndex: idx))
                    }
                    idx = item.text.string.index(after: idx)
                }
            }

            for match in PIIDetector.detect(in: normalizedText, types: types) {
                let matchedText = String(normalizedText[match.range])
                let nsRange = NSRange(match.range, in: normalizedText)

                // Span per original pair index
                var spanByPair: [Int: (start: String.Index, end: String.Index)] = [:]
                for ni in nsRange.location..<(nsRange.location + nsRange.length) {
                    guard ni < charMap.count else { continue }
                    let info = charMap[ni]
                    if let existing = spanByPair[info.pairIndex] {
                        spanByPair[info.pairIndex] = (existing.start, info.charIndex)
                    } else {
                        spanByPair[info.pairIndex] = (info.charIndex, info.charIndex)
                    }
                }

                // Union bounding boxes across contributing candidates
                var unionBox: CGRect? = nil
                for (pi, span) in spanByPair {
                    let (obs, text) = pairs[pi]
                    let s = text.string
                    let endExclusive = s.index(after: span.end)
                    let normBox = (try? text.boundingBox(for: span.start..<endExclusive))?.boundingBox ?? obs.boundingBox
                    unionBox = unionBox.map { $0.union(normBox) } ?? normBox
                }

                guard let box = unionBox else { continue }
                let pixelBox = visionToPixel(box, pixelSize: pixelSize)

                if !boxes.contains(where: { overlapping($0, pixelBox) }) {
                    if verbose { print("  Redacting [spaced \(match.type.rawValue)]: \"\(matchedText)\"") }
                    boxes.append(pixelBox)
                }
            }

            // Pass 3 — digit-run detection.
            // OCR on gridded forms often inserts extra characters (e.g. "1" from a thin
            // box border) between digit cells, inflating the run length by 1–2 and
            // defeating the (?<!\d)\d{N}(?!\d) word-boundary guards in PIIDetector.
            // For each maximal digit run that is slightly longer than a known pattern
            // length, treat the whole run as a match — the union box covers all the
            // digit cells regardless of the extra character(s).
            let digitRunSpecs: [(PIIType, exactLen: Int, maxExtra: Int)] = [
                (.ssn,        9,  2),
                (.creditCard, 16, 2),
            ]
            if let digitRunRx = try? NSRegularExpression(pattern: #"\d+"#) {
                let nsNorm    = normalizedText as NSString
                let fullRange = NSRange(location: 0, length: nsNorm.length)
                for result in digitRunRx.matches(in: normalizedText, range: fullRange) {
                    let runStart  = result.range.location
                    let runLength = result.range.length
                    for (piiType, exactLen, maxExtra) in digitRunSpecs {
                        guard types.contains(piiType) else { continue }
                        // Only fire when the run is longer than expected (normal pass
                        // handles exact-length runs) but within the noise tolerance.
                        guard runLength > exactLen && runLength <= exactLen + maxExtra else { continue }

                        var spanByPair: [Int: (start: String.Index, end: String.Index)] = [:]
                        for ni in runStart..<(runStart + runLength) {
                            guard ni < charMap.count else { continue }
                            let info = charMap[ni]
                            if let existing = spanByPair[info.pairIndex] {
                                spanByPair[info.pairIndex] = (existing.start, info.charIndex)
                            } else {
                                spanByPair[info.pairIndex] = (info.charIndex, info.charIndex)
                            }
                        }

                        var unionBox: CGRect? = nil
                        for (pi, span) in spanByPair {
                            let (obs, text) = pairs[pi]
                            let s = text.string
                            let endExclusive = s.index(after: span.end)
                            let normBox = (try? text.boundingBox(for: span.start..<endExclusive))?.boundingBox ?? obs.boundingBox
                            unionBox = unionBox.map { $0.union(normBox) } ?? normBox
                        }

                        guard let box = unionBox else { continue }
                        let pixelBox = visionToPixel(box, pixelSize: pixelSize)

                        if !boxes.contains(where: { overlapping($0, pixelBox) }) {
                            if verbose { print("  Redacting [digit-run \(piiType.rawValue)]: \(runLength)-digit run (expected \(exactLen))") }
                            boxes.append(pixelBox)
                        }
                    }
                }
            }
        }

        return boxes
    }

    private static func visionToPixel(_ box: CGRect, pixelSize: CGSize) -> CGRect {
        // Vision normalized coords: origin bottom-left, y increases upward.
        // CGBitmapContext native coords: same orientation (y=0 at bottom).
        // No Y-inversion needed — just scale to pixels.
        CGRect(
            x: box.minX * pixelSize.width,
            y: box.minY * pixelSize.height,
            width:  box.width  * pixelSize.width,
            height: box.height * pixelSize.height
        ).insetBy(dx: -3, dy: -3)
    }

    private static func overlapping(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let area = intersection.width * intersection.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && area / smaller > 0.5
    }

    private static func runOCR(on image: CGImage) throws -> [VNRecognizedTextObservation] {
        var results: [VNRecognizedTextObservation] = []
        var ocrError: Error?

        let request = VNRecognizeTextRequest { req, err in
            if let err { ocrError = err; return }
            results = req.results as? [VNRecognizedTextObservation] ?? []
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        if let ocrError { throw ocrError }
        return results
    }

    // MARK: - Save

    private static func saveImage(_ image: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let utType: UTType
        switch ext {
        case "jpg", "jpeg": utType = .jpeg
        case "tiff", "tif": utType = .tiff
        case "heic", "heif": utType = .heic
        case "bmp":         utType = .bmp
        default:            utType = .png
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw RedactError.saveFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RedactError.saveFailed(url.path)
        }
    }
}
