# pii-scrub-daddy

A macOS command-line tool that automatically detects and redacts PII from PDF files and images. Produces a flattened output — no hidden text layer.

## Features

- Detects PII using regex (SSN, phone, email, credit card, zip code) and Apple's `NaturalLanguage` framework (names, addresses)
- **PDFs**: uses `PDFKit` text extraction for digital PDFs and falls back to `Vision` OCR for scanned/image PDFs
- **Images**: uses `Vision` OCR on any supported image format
- PDF output is fully flattened — `extract_text()` returns nothing
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
piiscrub <input.pdf> <output.pdf> [--all] [--verbose]
piiscrub <input.png> <output.png> [--all] [--verbose]
```

Supported image formats: `png`, `jpg`, `jpeg`, `tiff`, `tif`, `heic`, `heif`, `bmp`, `webp`

**Directory** — redacts all PDFs and images in the directory, writing `redacted_<name>` into `<directory>/output/`
```sh
piiscrub <directory> [--all] [--verbose]
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
# Single PDF — redact SSN, phone, email, credit card (default)
piiscrub report.pdf redacted.pdf

# Single image — redact everything
piiscrub scan.png redacted.png --all --verbose

# Single PDF — redact everything
piiscrub report.pdf redacted.pdf --all --verbose

# Directory — batch redact all PDFs and images
piiscrub ~/Documents/invoices

# Directory — batch redact with all PII types
piiscrub ~/Documents/invoices --all --verbose
```

Directory output structure:
```
invoices/
├── invoice-001.pdf
├── photo-id.png
└── output/
    ├── redacted_invoice-001.pdf
    └── redacted_photo-id.png
```

## How it works

**PDFs**
1. Each page is rendered to a high-resolution bitmap via `CoreGraphics`
2. PII is located using `PDFKit`'s `findString` → `PDFSelection.bounds` (digital PDFs) or `Vision` OCR (scanned PDFs)
3. Black rectangles are painted over each match
4. Pages are saved as a new image-only PDF — the text layer is gone

**Images**
1. The image is loaded as a `CGImage`
2. `Vision` OCR scans the image for text and locates PII
3. Black rectangles are painted over each match
4. The result is saved in the same format as the input

## Uninstall

```sh
make uninstall
```
