PREFIX ?= /usr/local

.PHONY: build install uninstall clean

build:
	swift build -c release --arch arm64 --arch x86_64

install: build
	install -d $(PREFIX)/bin
	install .build/apple/Products/Release/touchenv $(PREFIX)/bin/touchenv

uninstall:
	rm -f $(PREFIX)/bin/touchenv

clean:
	swift package clean
