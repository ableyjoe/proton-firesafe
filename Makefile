# proton-firesafe: see README.md.
#
#   make install    install the script, its launcher and manual page, and a config file
#   make agent      install and start the daily launchd agent
#   make uninstall  stop the agent and remove what install put in place
#   make test       run the tests
#   make lint       check the script, launcher, manual page and agent
#
# Give install and agent the same PREFIX, and anything else you override.

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
MANDIR ?= $(PREFIX)/share/man
LABEL ?= nl.strandkip.proton-firesafe
# 03:17 happens exactly once on every day, daylight saving or not.
HOUR ?= 3
MINUTE ?= 17
CFLAGS ?= -O2 -Wall -Wextra

SCRIPT = $(BINDIR)/proton-firesafe
LAUNCHER = $(LIBEXECDIR)/proton-firesafe-launch
CONFDIR = $(HOME)/.config/proton-firesafe
AGENTDIR = $(HOME)/Library/LaunchAgents
AGENT = $(AGENTDIR)/$(LABEL).plist
DOMAIN = gui/$$(id -u)

all: proton-firesafe-launch
	@sed -n 's/^#   //p' Makefile

# The settings baked into the launcher and the agent. Each file is rewritten
# only when they change, so that its dependants are rebuilt only then: a
# rebuilt launcher needs Full Disk Access granting again.
.launch.conf: FORCE
	@echo 'SCRIPT=$(SCRIPT)' >$@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

.agent.conf: FORCE
	@echo 'LAUNCHER=$(LAUNCHER) LABEL=$(LABEL) HOME=$(HOME) HOUR=$(HOUR) MINUTE=$(MINUTE)' >$@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

proton-firesafe-launch: proton-firesafe-launch.c .launch.conf
	$(CC) $(CFLAGS) -DSCRIPT='"$(SCRIPT)"' -o $@ proton-firesafe-launch.c
	@if command -v codesign >/dev/null; then \
		echo "codesign -s - $@"; \
		codesign -s - -f -i $(LABEL)-launch $@; \
	fi

$(LABEL).plist: launchd.plist.in .agent.conf
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@LAUNCHER@|$(LAUNCHER)|g' \
	    -e 's|@HOME@|$(HOME)|g' -e 's|@HOUR@|$(HOUR)|g' \
	    -e 's|@MINUTE@|$(MINUTE)|g' launchd.plist.in >$@

install: proton-firesafe-launch
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBEXECDIR) $(DESTDIR)$(MANDIR)/man1
	install -m 0755 proton-firesafe $(DESTDIR)$(SCRIPT)
	install -C -m 0755 proton-firesafe-launch $(DESTDIR)$(LAUNCHER)
	install -m 0644 proton-firesafe.1 $(DESTDIR)$(MANDIR)/man1/proton-firesafe.1
	@if [ -z "$(DESTDIR)" ] && [ ! -f $(CONFDIR)/config ]; then \
		install -d -m 0700 $(CONFDIR) && \
		install -m 0600 config.example $(CONFDIR)/config && \
		echo "Installed $(CONFDIR)/config; check MAILTO in it."; \
	fi

agent: proton-firesafe-launch $(LABEL).plist
	@if [ ! -x $(SCRIPT) ] || ! cmp -s proton-firesafe-launch $(LAUNCHER); then \
		echo "Run make install first, with the same PREFIX."; exit 1; \
	fi
	install -d $(AGENTDIR)
	install -m 0644 $(LABEL).plist $(AGENT)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) $(AGENT)
	@printf '\nproton-firesafe will run daily at %d:%02d. Before it does, give\n\n' $(HOUR) $(MINUTE)
	@printf '  %s\n\n' $(LAUNCHER)
	@echo "Full Disk Access: System Settings > Privacy & Security > Full Disk"
	@echo "Access, click +, press Cmd-Shift-G, and paste that path. Then, to run"
	@echo "it now:"
	@echo
	@echo "  launchctl kickstart $(DOMAIN)/$(LABEL)"

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT) $(SCRIPT) $(LAUNCHER) $(MANDIR)/man1/proton-firesafe.1
	@echo "Left alone: $(CONFDIR), the state in ~/Library/Application Support,"
	@echo "the logs in ~/Library/Logs, and the takeouts on the disks. Remove"
	@echo "the launcher from Full Disk Access in System Settings, too."

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
	$(CC) -Wall -Wextra -Werror -fsyntax-only -DSCRIPT='"$(SCRIPT)"' proton-firesafe-launch.c
	mandoc -T lint -W warning proton-firesafe.1
	if command -v plutil >/dev/null; then plutil -lint $(LABEL).plist; \
	else xmllint --noout $(LABEL).plist; fi

clean:
	rm -f $(LABEL).plist proton-firesafe-launch .launch.conf .agent.conf *.new

FORCE:

.PHONY: all install agent uninstall test lint clean FORCE
