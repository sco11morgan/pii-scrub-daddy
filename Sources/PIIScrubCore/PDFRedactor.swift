import Foundation
import PDFKit
import Vision
import CoreGraphics
import AppKit

public struct PDFRedactor {

    public static func redact(inputURL: URL, outputURL: URL, types: Set<PIIType> = PIIType.defaults, verbose: Bool = false) throws {
        guard let document = PDFDocument(url: inputURL) else {
            throw RedactError.cannotLoadPDF(inputURL.path)
        }

        let pageCount = document.pageCount
        var cgImages: [CGImage] = []

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if verbose { print("Processing page \(pageIndex + 1)/\(pageCount)...") }

            let image = try redactPage(page, pageIndex: pageIndex, types: types, verbose: verbose)
            cgImages.append(image)
        }

        try saveAsPDF(images: cgImages, to: outputURL)
        if verbose { print("Saved redacted PDF to \(outputURL.path)") }
    }

    // MARK: - Per-page redaction

    private static func redactPage(_ page: PDFPage, pageIndex: Int, types: Set<PIIType>, verbose: Bool) throws -> CGImage {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let pixelSize = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)

        // 1. Render PDF page to bitmap (flip so bitmap origin is top-left)
        guard let context = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RedactError.renderFailed(pageIndex)
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))

        // PDF origin = bottom-left; flip when drawing into top-left CGContext
        context.saveGState()
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let renderedImage = context.makeImage() else {
            throw RedactError.renderFailed(pageIndex)
        }

        // 2. Find PII redaction boxes
        let redactBoxes = findRedactionBoxes(page: page, pixelSize: pixelSize, scale: scale,
                                             mediaBox: mediaBox, renderedImage: renderedImage,
                                             types: types, verbose: verbose)

        // 3. Paint black boxes
        if !redactBoxes.isEmpty {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            for box in redactBoxes {
                context.fill(box)
            }
        }

        guard let finalImage = context.makeImage() else {
            throw RedactError.renderFailed(pageIndex)
        }
        return finalImage
    }

    // MARK: - PII location

    /// Returns redaction boxes in bitmap coordinates (top-left origin).
    /// Prefers PDFKit character bounds for digital PDFs; falls back to Vision OCR for scanned PDFs
    /// or PDFs where the text layer uses a custom font encoding that defeats text extraction.
    private static func findRedactionBoxes(page: PDFPage, pixelSize: CGSize, scale: CGFloat,
                                           mediaBox: CGRect, renderedImage: CGImage,
                                           types: Set<PIIType>, verbose: Bool) -> [CGRect] {
        // Try PDFKit text extraction first (works for digital/searchable PDFs)
        if let pageText = page.string, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if verbose { print("  Using PDFKit text extraction") }
            let boxes = pdfKitRedactionBoxes(page: page, pageText: pageText, mediaBox: mediaBox,
                                             scale: scale, types: types, verbose: verbose)
            if !boxes.isEmpty { return boxes }

            // PDFKit extracted text but found no PII — the font may use a custom encoding
            // where character codes for digits/names map to wrong Unicode values, making the
            // text appear garbled or digit-free even though PII is visually present.
            // Fall through to Vision OCR to catch what text extraction missed.
            if verbose { print("  No PII in text layer (possible custom font encoding), trying Vision OCR") }
        } else {
            if verbose { print("  No text layer found, using Vision OCR") }
        }

        return (try? ocrRedactionBoxes(image: renderedImage, pixelSize: pixelSize, types: types, verbose: verbose)) ?? []
    }

    private static func pdfKitRedactionBoxes(page: PDFPage, pageText: String, mediaBox: CGRect,
                                             scale: CGFloat, types: Set<PIIType>, verbose: Bool) -> [CGRect] {
        var boxes: [CGRect] = []

        // Pass 1: match against the raw page text (handles normal PDFs)
        let piiMatches = PIIDetector.detect(in: pageText, types: types)
        for match in piiMatches {
            let matchedText = String(pageText[match.range])
            if verbose { print("  Redacting [\(match.type.rawValue)]: \"\(matchedText)\"") }

            guard let doc = page.document else { continue }
            let selections = doc.findString(matchedText, withOptions: [.caseInsensitive])

            var found = false
            for sel in selections {
                guard sel.pages.contains(page) else { continue }
                found = true
                let pdfBox = sel.bounds(for: page)
                boxes.append(pdfBoxToPixel(pdfBox, mediaBox: mediaBox, scale: scale))
            }

            if !found {
                let nsRange = NSRange(match.range, in: pageText)
                var unionBox: CGRect? = nil
                for i in nsRange.location..<(nsRange.location + nsRange.length) {
                    let cb = page.characterBounds(at: i)
                    guard !cb.isEmpty else { continue }
                    unionBox = unionBox.map { $0.union(cb) } ?? cb
                }
                if let pdfBox = unionBox {
                    boxes.append(pdfBoxToPixel(pdfBox, mediaBox: mediaBox, scale: scale))
                }
            }
        }

        // Pass 2: normalized match — collapses whitespace so spaced form fields like
        // "3 7 9 - 7 8 - 3 2 1 8" are detected. Builds an NSString index map so we
        // can call characterBounds(at:) with the correct original indices.
        let nsPageText = pageText as NSString
        var normalizedText = ""
        var nsIndexMap: [Int] = []  // normalized position → original NSString code-unit index
        for i in 0..<nsPageText.length {
            let c = nsPageText.character(at: i)
            // Skip whitespace (space = 0x20, tab = 0x09, newline = 0x0A, CR = 0x0D, etc.)
            guard c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D else { continue }
            if let scalar = Unicode.Scalar(c) {
                normalizedText.append(Character(scalar))
                nsIndexMap.append(i)
            }
        }

        let normalizedMatches = PIIDetector.detect(in: normalizedText, types: types)
        for match in normalizedMatches {
            let matchedText = String(normalizedText[match.range])
            let nsNormRange  = NSRange(match.range, in: normalizedText)

            // Reconstruct the original text span (with spaces) so we can use findString,
            // which returns accurate PDFSelection bounds unlike characterBounds(at:).
            guard nsNormRange.location < nsIndexMap.count,
                  nsNormRange.location + nsNormRange.length - 1 < nsIndexMap.count else { continue }
            let firstOrigIdx = nsIndexMap[nsNormRange.location]
            let lastOrigIdx  = nsIndexMap[nsNormRange.location + nsNormRange.length - 1]
            let origSpanRange = NSRange(location: firstOrigIdx, length: lastOrigIdx - firstOrigIdx + 1)
            let originalSpacedText = nsPageText.substring(with: origSpanRange)

            var pdfBox: CGRect?

            // Prefer findString — it uses the real content stream positions
            if let doc = page.document {
                let sels = doc.findString(originalSpacedText, withOptions: [.caseInsensitive])
                for sel in sels {
                    guard sel.pages.contains(page) else { continue }
                    pdfBox = sel.bounds(for: page)
                    break
                }
            }

            // Fall back to union of characterBounds if findString failed
            if pdfBox == nil {
                var unionBox: CGRect? = nil
                for ni in nsNormRange.location..<(nsNormRange.location + nsNormRange.length) {
                    guard ni < nsIndexMap.count else { continue }
                    let origIndex = nsIndexMap[ni]
                    let cb = page.characterBounds(at: origIndex)
                    guard !cb.isEmpty else { continue }
                    unionBox = unionBox.map { $0.union(cb) } ?? cb
                }
                pdfBox = unionBox
            }

            guard let finalPdfBox = pdfBox else { continue }
            let pixelBox = pdfBoxToPixel(finalPdfBox, mediaBox: mediaBox, scale: scale)

            // Only add if not already covered by a box from pass 1
            if !boxes.contains(where: { $0.intersects(pixelBox) && overlapping($0, pixelBox) }) {
                if verbose { print("  Redacting [spaced \(match.type.rawValue)]: \"\(matchedText)\"") }
                boxes.append(pixelBox)
            }
        }

        // Pass 3: AcroForm widget annotations — fillable form field values are stored
        // in PDFAnnotation objects and are NOT included in page.string.
        for annotation in page.annotations {
            guard let fieldText = annotation.widgetStringValue, !fieldText.isEmpty else { continue }

            // Run detection on raw value and whitespace-collapsed value
            let collapsed = String(fieldText.filter { !$0.isWhitespace })
            let candidates = fieldText == collapsed ? [fieldText] : [fieldText, collapsed]

            for text in candidates {
                let matches = PIIDetector.detect(in: text, types: types)
                guard !matches.isEmpty else { continue }

                let pdfBox   = annotation.bounds
                let pixelBox = pdfBoxToPixel(pdfBox, mediaBox: mediaBox, scale: scale)

                if !boxes.contains(where: { overlapping($0, pixelBox) }) {
                    if verbose {
                        let typeNames = matches.map(\.type.rawValue).joined(separator: ", ")
                        print("  Redacting [AcroForm \(typeNames)]: \"\(fieldText)\"")
                    }
                    boxes.append(pixelBox)
                }
                break  // don't double-add for same annotation
            }
        }

        return boxes
    }

    /// Returns true if two rects overlap by more than 50% of the smaller rect's area.
    private static func overlapping(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let area = intersection.width * intersection.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && area / smaller > 0.5
    }

    /// Converts a rect in PDF page space (bottom-left origin) to bitmap pixel space (top-left origin).
    private static func pdfBoxToPixel(_ pdfBox: CGRect, mediaBox: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (pdfBox.minX - mediaBox.minX) * scale,
            y: (mediaBox.maxY - pdfBox.maxY) * scale,
            width:  pdfBox.width  * scale,
            height: pdfBox.height * scale
        ).insetBy(dx: -3, dy: -3)
    }

    private static func ocrRedactionBoxes(image: CGImage, pixelSize: CGSize, types: Set<PIIType>, verbose: Bool) throws -> [CGRect] {
        var boxes: [CGRect] = []
        let observations = try runOCR(on: image)

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let fullText = candidate.string
            if verbose { print("  OCR: \"\(fullText)\"") }

            let piiMatches = PIIDetector.detect(in: fullText, types: types)
            for match in piiMatches {
                if verbose {
                    print("  Redacting [\(match.type.rawValue)]: \"\(fullText[match.range])\"")
                }

                let box: CGRect
                if let matchBox = try? candidate.boundingBox(for: match.range) {
                    box = matchBox.boundingBox
                } else {
                    box = obs.boundingBox
                }

                // Vision bounding box: normalized, origin bottom-left → pixel top-left
                let pixelBox = CGRect(
                    x: box.minX * pixelSize.width,
                    y: (1 - box.maxY) * pixelSize.height,
                    width: box.width * pixelSize.width,
                    height: box.height * pixelSize.height
                ).insetBy(dx: -3, dy: -3)
                boxes.append(pixelBox)
            }
        }
        return boxes
    }

    // MARK: - OCR

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

    // MARK: - Save (flip image: bitmap is top-left, PDF context is bottom-left)

    private static func saveAsPDF(images: [CGImage], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw RedactError.saveFailed(url.path)
        }

        for image in images {
            let pageBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            var mutableBox = pageBox
            pdfContext.beginPage(mediaBox: &mutableBox)

            // Flip: bitmap top-left → PDF bottom-left
            pdfContext.saveGState()
            pdfContext.translateBy(x: 0, y: CGFloat(image.height))
            pdfContext.scaleBy(x: 1, y: -1)
            pdfContext.draw(image, in: pageBox)
            pdfContext.restoreGState()

            pdfContext.endPage()
        }
        pdfContext.closePDF()
    }
}

// MARK: - Errors

public enum RedactError: LocalizedError {
    case cannotLoadPDF(String)
    case cannotLoadImage(String)
    case renderFailed(Int)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotLoadPDF(let path):    return "Cannot load PDF: \(path)"
        case .cannotLoadImage(let path):  return "Cannot load image: \(path)"
        case .renderFailed(let page):     return "Failed to render page \(page + 1)"
        case .saveFailed(let path):       return "Failed to save to: \(path)"
        }
    }
}
