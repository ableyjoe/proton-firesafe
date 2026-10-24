# proton-firesafe: see README.md.
#
#   make install    install the script and manual page, and a config file
#   make agent      install and start the daily launchd agent
#   make uninstall  stop the agent and remove what install put in place
#   make test       run the tests
#   make lint       check the script, manual page and agent

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
LABEL ?= nl.strandkip.proton-firesafe
# 03:17 happens exactly once on every day, daylight saving or not.
HOUR ?= 3
MINUTE ?= 17

CONFDIR = $(HOME)/.config/proton-firesafe
AGENTDIR = $(HOME)/Library/LaunchAgents
AGENT = $(AGENTDIR)/$(LABEL).plist
DOMAIN = gui/$$(id -u)

all:
	@sed -n 's/^#   //p' Makefile

install:
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)/man1
	install -m 0755 proton-firesafe $(DESTDIR)$(BINDIR)/proton-firesafe
	install -m 0644 proton-firesafe.1 $(DESTDIR)$(MANDIR)/man1/proton-firesafe.1
	@if [ -z "$(DESTDIR)" ] && [ ! -f $(CONFDIR)/config ]; then \
		install -d -m 0700 $(CONFDIR) && \
		install -m 0600 config.example $(CONFDIR)/config && \
		echo "Installed $(CONFDIR)/config; check MAILTO in it."; \
	fi

$(LABEL).plist: launchd.plist.in Makefile
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@BINDIR@|$(BINDIR)|g' \
	    -e 's|@HOME@|$(HOME)|g' -e 's|@HOUR@|$(HOUR)|g' \
	    -e 's|@MINUTE@|$(MINUTE)|g' launchd.plist.in >$@

agent: $(LABEL).plist
	@[ -x $(BINDIR)/proton-firesafe ] || { echo "Run make install first."; exit 1; }
	install -d $(AGENTDIR)
	install -m 0644 $(LABEL).plist $(AGENT)
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	launchctl bootstrap $(DOMAIN) $(AGENT)
	@echo "proton-firesafe will run daily at $(HOUR):$(MINUTE). To run it now:"
	@echo "  launchctl kickstart $(DOMAIN)/$(LABEL)"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(BINDIR)/proton-firesafe $(MANDIR)/man1/proton-firesafe.1
	@echo "Left alone: $(CONFDIR), the state in ~/Library/Application Support,"
	@echo "the logs in ~/Library/Logs, and the takeouts on the disks."

test:
	sh tests/run-tests.sh
	@for sh in dash "bash --posix"; do \
		if command -v $${sh%% *} >/dev/null; then \
			echo "# with $$sh"; \
			out=$$(TEST_SHELL="$$sh" sh tests/run-tests.sh) || { echo "$$out"; exit 1; }; \
			echo "$$out" | tail -n 1; \
		fi; \
	done

lint: $(LABEL).plist
	shellcheck -s sh proton-firesafe tests/run-tests.sh tests/stubs/*
	mandoc -T lint -W warning proton-firesafe.1
	if command -v plutil >/dev/null; then plutil -lint $(LABEL).plist; \
	else xmllint --noout $(LABEL).plist; fi

clean:
	rm -f $(LABEL).plist

.PHONY: all install agent uninstall test lint clean
