# redact-pdf

A macOS command-line tool that automatically detects and redacts PII from PDF files. Produces a flattened image-only PDF — no hidden text layer.

## Features

- Detects PII using regex (SSN, phone, email, credit card, zip code) and Apple's `NaturalLanguage` framework (names, addresses)
- Uses `PDFKit` text extraction for digital PDFs and falls back to `Vision` OCR for scanned/image PDFs
- Outputs a fully flattened PDF — `extract_text()` returns nothing
- Supports single file or batch directory processing

## Requirements

- macOS 13+
- Xcode / Swift toolchain

## Build

```sh
make           # debug build
make release   # optimized build
```

## Install

```sh
make install                  # installs to /usr/local/bin
PREFIX=~/.local make install  # custom prefix
```

## Usage

**Single file**
```sh
redact-pdf <input.pdf> <output.pdf> [--all] [--verbose]
```

**Directory** — redacts all PDFs in the directory, writing `redacted_<name>.pdf` into `<directory>/output/`
```sh
redact-pdf <directory> [--all] [--verbose]
```

**Options**

| Flag | Description |
|------|-------------|
| `--all` | Also redact zip codes, person names, and addresses (see table below) |
| `--verbose` | Print each redacted item and page progress |
| `--help` | Show usage |

**PII types**

| Type | Default | `--all` |
|------|:-------:|:-------:|
| SSN (`XXX-XX-XXXX` or 9 digits) | ✓ | ✓ |
| Phone number | ✓ | ✓ |
| Email address | ✓ | ✓ |
| Credit card number | ✓ | ✓ |
| Zip code | | ✓ |
| Person name (NLP) | | ✓ |
| Place / organization name (NLP) | | ✓ |

## Examples

```sh
# Single file — redact SSN, phone, email, credit card (default)
redact-pdf report.pdf redacted.pdf

# Single file — redact everything
redact-pdf report.pdf redacted.pdf --all --verbose

# Directory — batch redact all PDFs
redact-pdf ~/Documents/invoices

# Directory — batch redact with all PII types
redact-pdf ~/Documents/invoices --all --verbose
```

Directory output structure:
```
invoices/
├── invoice-001.pdf
├── invoice-002.pdf
└── output/
    ├── redacted_invoice-001.pdf
    └── redacted_invoice-002.pdf
```

## How it works

1. Each page is rendered to a high-resolution bitmap via `CoreGraphics`
2. PII is located using `PDFKit`'s `findString` → `PDFSelection.bounds` (digital PDFs) or `Vision` OCR (scanned PDFs)
3. Black rectangles are painted over each match
4. Pages are saved as a new image-only PDF — the text layer is gone

## Uninstall

```sh
make uninstall
```
