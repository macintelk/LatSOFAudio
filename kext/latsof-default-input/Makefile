# Makefile for latsof-default-input
#
# Builds a universal (x86_64 + arm64) CoreAudio CLI tool that sets the
# LatSOF input device as the system default input. No external deps beyond
# macOS system frameworks.
#
# NOTE: the kext build script one level up (`../build.sh`) builds this
# tool too, so you normally don't need `make` at all — `make` here is
# only for install/uninstall and the test targets.
#
#   make          # build (only if you don't use ../build.sh)
#   make install  # install to ~/Library/Application Support/LatSOF + load LaunchAgent
#   make uninstall
#
# Run `make install` from your own shell — no sudo needed: the LaunchAgent
# goes into ~/Library/LaunchAgents and the binary into a per-user path.

PROG      = latsof-default-input
BINDIR    = $(HOME)/Library/Application Support/LatSOF
LABEL     = local.latsof.default-input
PLIST_SRC = $(LABEL).plist
PLIST_DST = $(HOME)/Library/LaunchAgents/$(LABEL).plist

SDKROOT  ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CC        = clang
ARCHES    = x86_64 arm64
CFLAGS    = -O2 -Wall -Wextra -std=c11 \
            $(addprefix -arch ,$(ARCHES)) \
            $(SDKROOT:%=-isysroot %) \
            -mmacosx-version-min=11.0
LDFLAGS   = $(addprefix -arch ,$(ARCHES)) \
            -framework CoreAudio -framework CoreFoundation

all: $(PROG)

$(PROG): $(PROG).c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "--- seal ---"
	@codesign --force --sign - $@
	@codesign --verify --strict $@ && echo "build seal OK"

dry-run: $(PROG)
	./$(PROG) --dry-run

# Build then run once in --watch mode for a foreground debug session (Ctrl-C to stop).
smoke: $(PROG)
	./$(PROG) --watch

install: $(PROG)
	@echo "=== install binary ==="
	mkdir -p "$(BINDIR)"
	install -m 0755 $(PROG) "$(BINDIR)/$(PROG)"
	@echo "=== install LaunchAgent ==="
	mkdir -p "$(dir $(PLIST_DST))"
	# Substitute the binary path into the plist so the agent calls this user's copy.
	sed -e "s#@BINDIR@#$(BINDIR)#g" "$(PLIST_SRC)" > "$(PLIST_DST)"
	@echo "=== load ==="
	-launchctl unload  "$(PLIST_DST)" 2>/dev/null || true
	launchctl   load   "$(PLIST_DST)"
	@echo "=== status ==="
	launchctl list | grep "$(LABEL)" || true
	@echo "---"
	@echo "Installed. The agent will:"
	@echo "  - run ONCE at each login"
	@echo "  - wait up to 30 s for the LatSOF device, set it as default"
	@echo "    input, then exit (no polling, never fights your later choices)"
	@echo "Inspect logs:  log show --predicate 'processImagePath contains \"latsof-default-input\"' --last 5m"
	@echo "Stop:          make uninstall"

uninstall:
	@echo "=== unload + remove ==="
	-launchctl unload "$(PLIST_DST)" 2>/dev/null || true
	rm -f  "$(PLIST_DST)"
	rm -f  "$(BINDIR)/$(PROG)"
	@echo "Removed. macOS will fall back to whatever default input was set before."

clean:
	rm -f $(PROG)

.PHONY: all dry-run smoke install uninstall clean
