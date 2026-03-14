import Foundation
import PIIScrubCore

// MARK: - Argument parsing

func printUsage() {
    print("""
    Usage:
      piiscrub <input.pdf> <output.pdf> [--all] [--verbose]
      piiscrub <input.png> <output.png> [--all] [--verbose]
      piiscrub <directory>              [--all] [--verbose]

    Single file:
      Redacts <input> and writes to <output>.
      Supported formats: pdf, png, jpg, jpeg, tiff, tif, heic, heif, bmp, webp

    Directory:
      Redacts all PDFs and images in <directory> and writes redacted_<name>
      into <directory>/output/.

    Options:
      --all       Also redact ZipCode, Person, and Address (default: SSN, Phone, Email, CreditCard)
      --verbose   Print each redacted item and page progress

    Examples:
      piiscrub document.pdf redacted.pdf --all --verbose
      piiscrub photo.png redacted.png
      piiscrub ~/Documents/invoices --verbose
    """)
}

var args = CommandLine.arguments.dropFirst()

if args.isEmpty || args.contains("--help") || args.contains("-h") {
    printUsage()
    exit(0)
}

let verbose  = args.contains("--verbose")
let allTypes = args.contains("--all")
let types: Set<PIIType> = allTypes ? PIIType.all : PIIType.defaults
args = args.filter { $0 != "--verbose" && $0 != "--all" }

let fm = FileManager.default

// MARK: - Helpers

func isPDF(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "pdf"
}

func isImage(_ url: URL) -> Bool {
    ImageRedactor.supportedExtensions.contains(url.pathExtension.lowercased())
}

func redactFile(inputURL: URL, outputURL: URL) throws {
    if isPDF(inputURL) {
        try PDFRedactor.redact(inputURL: inputURL, outputURL: outputURL, types: types, verbose: verbose)
    } else {
        try ImageRedactor.redact(inputURL: inputURL, outputURL: outputURL, types: types, verbose: verbose)
    }
}

// MARK: - Dispatch: directory vs single file

var isDir: ObjCBool = false

if args.count == 1 {
    // Directory mode
    let dirPath = args[args.startIndex]
    guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
        fputs("Error: '\(dirPath)' is not a directory\n", stderr)
        printUsage()
        exit(1)
    }

    let dirURL    = URL(fileURLWithPath: dirPath)
    let outputDir = dirURL.appendingPathComponent("output")

    do {
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
    } catch {
        fputs("Error: could not create output directory: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let files = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil))?.filter {
        isPDF($0) || isImage($0)
    } ?? []

    if files.isEmpty {
        print("No PDF or image files found in \(dirPath)")
        exit(0)
    }

    var failed = 0
    for inputURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let outputName = "redacted_\(inputURL.lastPathComponent)"
        let outputURL  = outputDir.appendingPathComponent(outputName)

        if verbose { print("\n[\(inputURL.lastPathComponent)] → output/\(outputName)") }
        do {
            try redactFile(inputURL: inputURL, outputURL: outputURL)
            if !verbose { print("✓ \(inputURL.lastPathComponent) → output/\(outputName)") }
        } catch {
            fputs("✗ \(inputURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
            failed += 1
        }
    }

    print("\nDone. \(files.count - failed)/\(files.count) files redacted.")
    exit(failed > 0 ? 1 : 0)

} else if args.count == 2 {
    // Single file mode
    let inputPath  = args[args.startIndex]
    let outputPath = args[args.index(after: args.startIndex)]
    let inputURL   = URL(fileURLWithPath: inputPath)
    let outputURL  = URL(fileURLWithPath: outputPath)

    guard fm.fileExists(atPath: inputPath) else {
        fputs("Error: input file not found: \(inputPath)\n", stderr)
        exit(1)
    }

    guard isPDF(inputURL) || isImage(inputURL) else {
        fputs("Error: unsupported file type '.\(inputURL.pathExtension)'\n", stderr)
        fputs("Supported: pdf, \(ImageRedactor.supportedExtensions.sorted().joined(separator: ", "))\n", stderr)
        exit(1)
    }

    do {
        if verbose { print("Redacting \(inputPath) → \(outputPath) [\(types.map(\.rawValue).sorted().joined(separator: ", "))]") }
        try redactFile(inputURL: inputURL, outputURL: outputURL)
        print("Done.")
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

} else {
    fputs("Error: unexpected arguments\n", stderr)
    printUsage()
    exit(1)
}
