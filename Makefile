# smbmounter — build & install
#
# Targets:
#   make build      compile the release binary
#   make test       run the unit test suite
#   make install    install binary, config (if absent), plist, log rotation  [sudo]
#   make load       bootstrap the LaunchDaemon                                [sudo]
#   make unload     bootout the LaunchDaemon                                  [sudo]
#   make uninstall  unload and remove all installed files                    [sudo]
#   make clean      remove build artifacts

LABEL       := com.brian.smbmounter
PREFIX      := /usr/local
BIN_DIR     := $(PREFIX)/sbin
ETC_DIR     := $(PREFIX)/etc/smbmounter
BIN         := $(BIN_DIR)/smbmounter
CONFIG      := $(ETC_DIR)/config.toml
PLIST_SRC   := $(LABEL).plist
PLIST_DST   := /Library/LaunchDaemons/$(LABEL).plist
NEWSYSLOG   := /etc/newsyslog.d/$(LABEL).conf
RELEASE_BIN := .build/release/smbmounter

INSTALL := /usr/bin/install

.PHONY: build test clean install load unload uninstall

build:
	swift build -c release

test:
	swift test

clean:
	swift package clean
	rm -rf .build

# Installs binary + plist + log-rotation always; installs config only if absent
# (never clobber an existing config).
install: build
	$(INSTALL) -d -m 0755 -o root -g wheel $(BIN_DIR)
	$(INSTALL) -m 0755 -o root -g wheel $(RELEASE_BIN) $(BIN)
	$(INSTALL) -d -m 0755 -o root -g wheel $(ETC_DIR)
	@if [ -f $(CONFIG) ]; then \
		echo "keeping existing $(CONFIG)"; \
	else \
		$(INSTALL) -m 0644 -o root -g wheel config.example.toml $(CONFIG); \
		echo "installed example config to $(CONFIG) — edit it, then run 'sudo smbmounter setup <name>'"; \
	fi
	$(INSTALL) -m 0644 -o root -g wheel $(PLIST_SRC) $(PLIST_DST)
	$(INSTALL) -m 0644 -o root -g wheel smbmounter.newsyslog.conf $(NEWSYSLOG)
	@echo ""
	@echo "Installed. Next:"
	@echo "  1. edit  $(CONFIG)"
	@echo "  2. sudo smbmounter setup <name>     # store the SMB credential"
	@echo "  3. make load                        # start the daemon"

load:
	launchctl bootstrap system $(PLIST_DST)
	launchctl print system/$(LABEL) >/dev/null && echo "loaded $(LABEL)"

unload:
	-launchctl bootout system $(PLIST_DST)

uninstall: unload
	rm -f $(BIN) $(PLIST_DST) $(NEWSYSLOG)
	rm -f /var/run/smbmounter.sock
	@echo "Removed binary, plist, log-rotation, and socket."
	@echo "Left in place (remove by hand if you want them gone):"
	@echo "  $(ETC_DIR)        (your config)"
	@echo "  /var/log/smbmounter.log /var/log/smbmounter.err"
	@echo "  System keychain credentials (use Keychain Access or 'security delete-internet-password')"
