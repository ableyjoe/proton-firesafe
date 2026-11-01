# proton-firesafe: see README.md.
#
#   make              build the launcher and the script, as yourself
#   doas make install install them, the manual page and a config file
#   make agent        install and start the daily launchd agent, as yourself
#   make unagent      stop and remove the agent, as yourself
#   doas make uninstall  remove what install put in place
#   make test         run the tests
#   make lint         check the script, launcher, manual page and agent
#
# Give every step the same PREFIX, and anything else you override. sudo
# does as well as doas.

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec
MANDIR ?= $(PREFIX)/share/man
SYSCONFDIR ?= $(PREFIX)/etc
LOCALSTATEDIR ?= /var
LABEL ?= nl.strandkip.proton-firesafe
# 03:17 happens exactly once on every day, daylight saving or not.
HOUR ?= 3
MINUTE ?= 17
CFLAGS ?= -O2 -Wall -Wextra
# The agent runs as whoever runs make install under doas or sudo, so its
# state and log directories belong to them.
AGENT_USER ?= $${DOAS_USER:-$${SUDO_USER:-$$(id -un)}}

SCRIPT = $(BINDIR)/proton-firesafe
LAUNCHER = $(LIBEXECDIR)/proton-firesafe-launch
CONFIG = $(SYSCONFDIR)/proton-firesafe.conf
STATEDIR = $(LOCALSTATEDIR)/db/proton-firesafe
LOGDIR = $(LOCALSTATEDIR)/log/proton-firesafe
LOG = $(LOGDIR)/proton-firesafe.log
AGENTDIR = $(HOME)/Library/LaunchAgents
AGENT = $(AGENTDIR)/$(LABEL).plist
DOMAIN = gui/$$(id -u)

all: proton-firesafe.out proton-firesafe-launch
	@sed -n 's/^#   //p' Makefile

# The settings baked into the script, the launcher and the agent. Each file
# is rewritten only when they change, so that what depends on it is rebuilt
# only then: a rebuilt launcher needs Full Disk Access granting again.
.script.conf: FORCE
	@echo 'CONFIG=$(CONFIG) STATEDIR=$(STATEDIR) LOG=$(LOG)' >$@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

.launch.conf: FORCE
	@echo 'SCRIPT=$(SCRIPT)' >$@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

.agent.conf: FORCE
	@echo 'LAUNCHER=$(LAUNCHER) LABEL=$(LABEL) LOGDIR=$(LOGDIR) HOUR=$(HOUR) MINUTE=$(MINUTE)' >$@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

proton-firesafe.out: proton-firesafe .script.conf
	sed -e 's|@CONFIG@|$(CONFIG)|g' -e 's|@STATEDIR@|$(STATEDIR)|g' \
	    -e 's|@LOG@|$(LOG)|g' proton-firesafe >$@
	chmod 0755 $@

proton-firesafe-launch: proton-firesafe-launch.c .launch.conf
	$(CC) $(CFLAGS) -DSCRIPT='"$(SCRIPT)"' -o $@ proton-firesafe-launch.c
	@if command -v codesign >/dev/null; then \
		echo "codesign -s - $@"; \
		codesign -s - -f -i $(LABEL)-launch $@; \
	fi

$(LABEL).plist: launchd.plist.in .agent.conf
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@LAUNCHER@|$(LAUNCHER)|g' \
	    -e 's|@LOGDIR@|$(LOGDIR)|g' -e 's|@HOUR@|$(HOUR)|g' \
	    -e 's|@MINUTE@|$(MINUTE)|g' launchd.plist.in >$@

install: proton-firesafe.out proton-firesafe-launch
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBEXECDIR) \
	    $(DESTDIR)$(MANDIR)/man1 $(DESTDIR)$(SYSCONFDIR)
	install -m 0755 proton-firesafe.out $(DESTDIR)$(SCRIPT)
	install -C -m 0755 proton-firesafe-launch $(DESTDIR)$(LAUNCHER)
	install -m 0644 proton-firesafe.1 $(DESTDIR)$(MANDIR)/man1/proton-firesafe.1
	@if [ ! -f $(DESTDIR)$(CONFIG) ]; then \
		echo "install -m 0644 config.example $(DESTDIR)$(CONFIG)"; \
		install -m 0644 config.example $(DESTDIR)$(CONFIG); \
		echo "Check MAILTO in $(CONFIG)."; \
	fi
	install -d -o "$(AGENT_USER)" -m 0755 $(DESTDIR)$(STATEDIR) $(DESTDIR)$(LOGDIR)

agent: proton-firesafe-launch $(LABEL).plist
	@if [ "$$(id -u)" -eq 0 ]; then \
		echo "Run make agent as yourself: the agent belongs to your login session."; \
		exit 1; \
	fi
	@if [ ! -x $(SCRIPT) ] || ! cmp -s proton-firesafe-launch $(LAUNCHER); then \
		echo "Run doas make install first, with the same PREFIX."; exit 1; \
	fi
	@if [ ! -w $(STATEDIR) ] || [ ! -w $(LOGDIR) ]; then \
		echo "$(STATEDIR) and $(LOGDIR) must belong to you; run doas make install."; \
		exit 1; \
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

unagent:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT)

uninstall:
	rm -f $(DESTDIR)$(SCRIPT) $(DESTDIR)$(LAUNCHER) $(DESTDIR)$(MANDIR)/man1/proton-firesafe.1
	@echo "Left alone: $(CONFIG), $(STATEDIR), $(LOGDIR),"
	@echo "and the takeouts on the disks. Remove the launcher from Full Disk"
	@echo "Access in System Settings, too."

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
	rm -f $(LABEL).plist proton-firesafe.out proton-firesafe-launch \
	    .script.conf .launch.conf .agent.conf *.new

FORCE:

.PHONY: all install agent unagent uninstall test lint clean FORCE
