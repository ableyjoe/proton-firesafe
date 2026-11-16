# AGENTS.md

Context for coding agents, and for anyone else, picking up proton-firesafe.
README.md is how to use it and proton-firesafe(1) is the reference; this is
why it is the way it is, and what was learnt building and deploying it.
Read all three before changing anything.

## What it is

A POSIX sh script, run daily by a launchd agent on a Mac, that keeps a
recent Proton Drive takeout (`proton-drive takeout run`) on whichever of
two encrypted external disks is attached, and sends mail when it is time
to swap that disk for the one in the fire safe. Proton holds the main copy;
the disks are the backup if Proton loses the data.

The author's deployment: a headless 2018 Intel Mac mini, macOS 15, with
MacPorts; `proton-drive` from the MacPorts port `proton-drive-cli`; msmtp
through the author's own mail host; two 4 TB WD My Passport disks,
`Firesafe-A` and `Firesafe-B`; about 500 GB in Proton Drive; for the
heartbeat, a check on the author's own OpenBSD server, with deadman
(github.com/ableyjoe/deadman), which replaced healthchecks.io. The author
uses ksh and doas, not bash and sudo, and runs commands on the Mac
himself: an agent working on this cannot reach it, so give commands to
type, one step at a time, and ask for their output.

## Files

| File | What |
|---|---|
| `proton-firesafe` | the script; `make` fills in its `@CONFIG@`, `@STATEDIR@` and `@LOG@` paths, into `proton-firesafe.out` |
| `proton-firesafe-launch.c` | the launcher that holds Full Disk Access (see below) |
| `launchd.plist.in` | the LaunchAgent template |
| `proton-firesafe.1` | the manual page, in mdoc |
| `config.example` | installed as the config file if there is none |
| `Makefile` | build, install, agent, test, lint |
| `tests/run-tests.sh`, `tests/stubs/` | the tests, and stand-ins for macOS and Proton commands |

Build and install in three steps, as three users:

```sh
make                 # as yourself: builds proton-firesafe.out and the launcher
doas make install    # as root: /usr/local/{bin,libexec,share/man,etc}, /var/{db,log}/proton-firesafe
make agent           # as yourself: ~/Library/LaunchAgents, gui/$UID domain
```

Give every step the same `PREFIX` and other overrides.

## Design decisions, and why

- **Proton's own takeout, not rclone.** rclone's Proton Drive backend is
  unofficial and was unreliable. `proton-drive takeout run` is always a
  full export. Re-running it into an existing folder renames instead of
  replacing (its conflict resolver is fixed at Rename for files and Merge
  for folders), so each run writes a new `takeout-YYYYmmdd-HHMMSS.partial`,
  renamed without `.partial` once `manifest.json` exists, which proton-drive
  writes only when every section has finished. It does not export Proton
  Docs or Sheets.
- **Partial failures count.** If some items fail, proton-drive still
  writes the manifest but exits non-zero. Such a takeout is kept, counted
  and reported (`failedItems` in the manifest), so that one file that will
  not download cannot block every takeout and swap.
- **launchd, not cron.** cron jobs run outside the login session, so they
  cannot read the login keychain, where proton-drive keeps its session,
  macOS keeps the disks' passwords, and msmtp's password lives.
- **The launcher, and Full Disk Access.** macOS refuses a launchd job
  access to an external disk unless the job's *responsible* program has
  Full Disk Access, and refuses silently: no dialog, just "Operation not
  permitted". For a script, the responsible program is the shell, and
  granting it would cover every shell script launchd runs. So the agent
  runs `proton-firesafe-launch`, which `posix_spawn`s the script and waits,
  as cron does, and gets Full Disk Access alone. The script's path is
  compiled in, so it can run nothing else. It is ad-hoc signed, so macOS
  ties the grant to the exact build: a rebuilt launcher needs granting
  again. That is why the Makefile's stamp files (`.launch.conf` and
  friends, rewritten only when their contents change) rebuild it only when
  `SCRIPT` changes; this works with macOS's GNU make 3.81.
- **Root owns what runs with that access.** The script, the launcher and
  the config file, which the script sources as code, belong to root, so the
  user's own account cannot change what runs with Full Disk Access. The
  exception is `passwordeval` in the user's `~/.msmtprc`, deliberately left
  as the user's. State (`/var/db/proton-firesafe`) and logs
  (`/var/log/proton-firesafe`) belong to the user the agent runs as;
  `make install` finds them from `DOAS_USER` or `SUDO_USER`. `/var`, not
  `/usr/local/var`, by the author's choice, as on the BSDs.
- **No file names outside the encrypted disk.** proton-drive's output
  names files, so it goes to `takeout-….log` on the disk. The script's own
  log and its mail never name files. proton-drive writes each file straight
  to the disk, with no copy on the Mac's own disk.
- **Encryption is enforced.** `init` and every takeout check `diskutil
  info` for `FileVault: Yes`; unencrypted volumes are refused unless
  `ALLOW_UNENCRYPTED=yes`.
- **Mail, weekly.** Silence must mean something, so every takeout is
  reported (what it holds, from the manifest; how long it took; the next
  takeout and swap), and a status report goes out if no mail has for
  `STATUS_EVERY_DAYS` (7). A run sends at most one such report: the swap
  request carries the report of the takeout before it. Subjects start
  `[proton-firesafe@HOST]` and every message has a signature with host,
  version and log, because mail clients replace the From display name;
  `MAILFROM` defaults to `MAILTO`. Problems use `remind KEY DAYS`, which
  sends at most once per interval.
- **Heartbeat.** `HEARTBEAT_URL` is fetched with curl at the start and end
  of every `run`, for a service such as healthchecks.io or deadman to
  alert when runs stop, the one failure no mail can report. Healthchecks
  ping URLs are `https://hc-ping.com/<uuid>` or
  `https://hc-ping.com/<ping-key>/<slug>`; a ping key alone is not one.
- **Watchdog.** launchd starts no new run while one is going, so a hung
  takeout would be silent; a background subshell mails after
  `TAKEOUT_WARN_HOURS`. It checks a flag file after sleeping, so killing it
  when the takeout ends cannot race it into a spurious mail.
- **Slack in every date comparison.** `days_between` adds four hours, for
  launchd's drift and daylight saving; reminders once compared exact
  seconds and skipped days. The agent runs at 03:17, which happens once on
  every day of the year, daylight saving or not.
- **Swaps.** Once a disk has been attached `SWAP_AFTER_DAYS` (28), the
  next run makes one more takeout, ejects it and asks for the swap, so the
  disk goes into the safe as fresh as it can. Only one disk should be
  attached: with both, the script would pick whichever has the older
  takeout, run to run. A disk swapped out and plugged back in is noticed.
- **Space.** Before a takeout, older takeouts are deleted if there might
  not be room for one the size of the newest, plus 10%, but never the
  newest. After it, `KEEP_TAKEOUTS` (2) are kept.

## Testing

```sh
make test    # runs tests/run-tests.sh under sh, dash and bash --posix
make lint    # shellcheck, the compiler, mandoc, plutil or xmllint
```

The tests run the script through simulated months: `PROTON_FIRESAFE_NOW`
sets the time, other `PROTON_FIRESAFE_*` variables point it at a scratch
directory, and `tests/stubs` stands in for `proton-drive`, `caffeinate`,
`diskutil` (ejecting moves a volume to a shelf), `msmtp` (appends to a
mailbox file), `df` and `curl`. They need nothing from macOS. The
uninstalled script refuses to run unless those variables are set.

Every behaviour change gets tests, and a bug fix gets a test that fails
without the fix: check new tests against the previous version of the
script (`git show HEAD:proton-firesafe`). Keep README.md and
proton-firesafe(1) in step with the code in the same commit.

## What was learnt on the real Mac

- `diskutil apfs encryptVolume` takes the volume's identifier (`disk3s1`,
  from `diskutil info /Volumes/NAME`), not the disk's or a mount point,
  and has no `-passprompt`: without `-passphrase` it asks. `diskutil info`
  then says `FileVault: Yes (Unlocked)`. To have a disk unlock itself, plug
  it in while watching the screen and tick "Remember this password in my
  keychain".
- `diskutil list` wraps volume names in U+2068 and U+2069; strip them
  before matching.
- proton-drive shows progress only on a terminal, so its log is quiet.
  It downloads five files at a time, up to ten 4 MiB blocks each, and reads
  each file back to check its SHA-1. Big files came down at 350–450 Mbit/s
  on a gigabit line; small files at about ten a second. The first takeout
  of about 500 GB took 19 hours, a later one about 11. Its memory can grow
  to about 19 GB during a takeout. Watch progress with `df`, not `du`,
  which crawls a disk that is being written.
- `install` unlinks before copying, so reinstalling the script under a
  running copy is safe, but there is no need: wait for a takeout to end.
- The author's PATH puts `~/local/bin` before `/usr/local/bin`; `hash -r`
  does not change the order. Check with `type proton-firesafe`.

## Conventions

- British English in documentation, mail and messages; plain words over
  idiom ("There has been nothing to report", not "Nothing has needed
  doing"); no Latin plurals for English words.
- Mail bodies wrap at about 72 columns, and say what to do next.
- Commit messages: a short imperative subject, then why.
- Propose design changes, and agree them with the author, before
  committing them.
