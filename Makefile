# saveclip — clipboard history daemon for macOS
# ──────────────────────────────────────────────────────────────────

SWIFT   := swift
BINARY  := .build/release/saveclip
DEBUG   := .build/debug/saveclip
PREFIX  := /usr/local
ZSH_SRC := saveclip.zsh
ZSH_DST := $(HOME)/.zsh/saveclip.zsh

# ── Build ────────────────────────────────────────────────────────

.PHONY: build release debug clean

build: release

release:
	$(SWIFT) build -c release

debug:
	$(SWIFT) build

clean:
	$(SWIFT) package clean

# ── Install / Uninstall ─────────────────────────────────────────

.PHONY: install uninstall link

install: release
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BINARY) $(DESTDIR)$(PREFIX)/bin/saveclip

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/saveclip

link:
	@echo "Linking zsh integration to $(ZSH_DST)"
	ln -sf $(CURDIR)/$(ZSH_SRC) $(ZSH_DST)

# ── Daemon ───────────────────────────────────────────────────────

.PHONY: start stop status

start: release
	$(BINARY) start

stop:
	$(BINARY) stop

status:
	$(BINARY) status

# ── Size report ──────────────────────────────────────────────────

.PHONY: size

size: release
	@ls -lh $(BINARY) | awk '{ printf "Binary size: %s\n", $$5 }'

# ── Line count ───────────────────────────────────────────────────

.PHONY: loc

loc:
	@echo ""
	@echo "Lines of code:"
	@if command -v tokei >/dev/null 2>&1; then \
		tokei Sources/; \
	else \
		find Sources -name '*.swift' | xargs wc -l | sort -n; \
	fi

# ── Help ─────────────────────────────────────────────────────────

.PHONY: help

help:
	@echo "saveclip — clipboard history daemon for macOS"
	@echo ""
	@echo "Build:"
	@echo "  make              Build release binary"
	@echo "  make debug        Build debug binary"
	@echo "  make clean        Remove build artifacts"
	@echo ""
	@echo "Install:"
	@echo "  make install      Install to $(PREFIX)/bin"
	@echo "  make uninstall    Remove from $(PREFIX)/bin"
	@echo "  make link         Symlink zsh integration to ~/.zsh/"
	@echo ""
	@echo "Daemon:"
	@echo "  make start        Start the clipboard daemon"
	@echo "  make stop         Stop the daemon"
	@echo "  make status       Check daemon status"
	@echo ""
	@echo "Other:"
	@echo "  make size         Binary size report"
	@echo "  make loc          Lines of code"

.DEFAULT_GOAL := help
