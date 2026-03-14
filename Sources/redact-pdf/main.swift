import Foundation

// MARK: - Argument parsing

func printUsage() {
    print("""
    Usage:
      redact-pdf <input.pdf> <output.pdf> [--all] [--verbose]
      redact-pdf <directory>             [--all] [--verbose]

    Single file:
      Redacts <input.pdf> and writes to <output.pdf>.

    Directory:
      Redacts all PDFs in <directory> and writes redacted_<name>.pdf
      into <directory>/output/.

    Options:
      --all       Also redact ZipCode, Person, and Address (default: SSN, Phone, Email, CreditCard)
      --verbose   Print each redacted item and page progress

    Examples:
      redact-pdf document.pdf redacted.pdf --all --verbose
      redact-pdf ~/Documents/invoices --verbose
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

    let pdfs = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil))?.filter {
        $0.pathExtension.lowercased() == "pdf"
    } ?? []

    if pdfs.isEmpty {
        print("No PDF files found in \(dirPath)")
        exit(0)
    }

    var failed = 0
    for inputURL in pdfs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let outputName = "redacted_\(inputURL.lastPathComponent)"
        let outputURL  = outputDir.appendingPathComponent(outputName)

        if verbose { print("\n[\(inputURL.lastPathComponent)] → output/\(outputName)") }
        do {
            try PDFRedactor.redact(inputURL: inputURL, outputURL: outputURL, types: types, verbose: verbose)
            if !verbose { print("✓ \(inputURL.lastPathComponent) → output/\(outputName)") }
        } catch {
            fputs("✗ \(inputURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
            failed += 1
        }
    }

    print("\nDone. \(pdfs.count - failed)/\(pdfs.count) files redacted.")
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

    do {
        if verbose { print("Redacting \(inputPath) → \(outputPath) [\(types.map(\.rawValue).sorted().joined(separator: ", "))]") }
        try PDFRedactor.redact(inputURL: inputURL, outputURL: outputURL, types: types, verbose: verbose)
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
