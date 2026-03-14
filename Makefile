BINARY   = redact-pdf
BUILD    = .build/release/$(BINARY)
PREFIX  ?= /usr/local

.PHONY: build release install uninstall clean

build:
	swift build

release:
	swift build -c release

install: release
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD) $(PREFIX)/bin/$(BINARY)

uninstall:
	rm -f $(PREFIX)/bin/$(BINARY)

clean:
	rm -rf .build
