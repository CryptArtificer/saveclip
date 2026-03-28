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

# install and deploy are the same — installs to both /usr/local/bin (CLI) and
# ~/.local/bin (launchd daemon), re-signs both (macOS kills unsigned copies),
# and restarts the daemon.
install: deploy

deploy: release
	@echo "Installing to $(PREFIX)/bin and ~/.local/bin..."
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BINARY) $(DESTDIR)$(PREFIX)/bin/saveclip
	codesign --sign - $(DESTDIR)$(PREFIX)/bin/saveclip
	mkdir -p $(HOME)/.local/bin
	cp $(BINARY) $(HOME)/.local/bin/saveclip
	codesign --sign - $(HOME)/.local/bin/saveclip
	@echo "Restarting daemon..."
	-launchctl kickstart -k gui/$$(id -u)/com.johjoh.saveclip 2>/dev/null || \
		($(BINARY) stop 2>/dev/null; sleep 0.5; $(BINARY) start)
	@if [ "$$(id -u)" = "0" ] && [ -n "$$SUDO_USER" ]; then \
		echo "Fixing .build/ ownership..."; \
		chown -R $$SUDO_USER:staff .build/; \
	fi
	@echo "Done."

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/saveclip
	rm -f $(HOME)/.local/bin/saveclip
	rm -f $(ZSH_DST)

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
	@echo "  make install      Install to both paths, re-sign, restart daemon"
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
