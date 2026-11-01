# proton-firesafe

Keeps an offline copy of a Proton Drive account on two external disks that
take turns between a Mac and a fire safe, and sends email when it is time
to swap them.

Proton Drive is end-to-end encrypted, but it is still one copy, in one
place, behind one account. This adds a second copy in your own house,
kept on encrypted disks, without handing your files to any other
service.

## How it works

Once a day, a launchd agent runs `proton-firesafe`, which:

- looks for one of the two disks, `Firesafe-A` or `Firesafe-B`;
- if the newest takeout on it is a week old, makes a fresh one with
  Proton's own `proton-drive takeout run`, keeping the two newest;
- once the disk has been attached for four weeks, makes one more takeout,
  ejects the disk, and emails you to put it in the fire safe and plug in
  the other one;
- if no disk is attached, emails you about that once a week.

So one disk always holds a takeout from the last week, and the one in the
fire safe one from the last month or so. Both are APFS (Encrypted), and
proton-firesafe will not write a takeout anywhere else. proton-drive
writes each file straight to its place on the disk, so no decrypted copy
lands on the Mac's own disk on the way. The emails never name your files:
the takeout's own output, which does, is kept on the encrypted disk.

## What you need

- **A Mac that stays on and logged in**, such as a Mac mini in a cupboard.
  The agent runs in your login session, because `proton-drive` keeps its
  session, and macOS keeps the disks' passwords, in the login keychain.
  Turn on automatic login so it comes back after a power cut.
- **The Xcode command-line tools**, to build the small launcher that
  holds the agent's Full Disk Access (see [The daily run](#the-daily-run)).
- **proton-drive**, Proton's command-line client: `port install
  proton-drive-cli`, or Proton's own download. Log it in once with
  `proton-drive auth login`.
- **msmtp**, to send the emails (`port install msmtp`), and an SMTP server
  you can send through, such as your mail provider's.
- **Two external disks**, each with room for two takeouts and a third in
  progress. With 500 GB in Proton Drive, 2 TB disks will do, and 4 TB
  disks leave room to grow. A spinning disk is fine: the takeout runs at
  the speed of your internet connection, not of the disk. Label them A
  and B.
- **Somewhere away from the Mac for the other disk**, such as a fire safe.
  A safe made for paper (UL 72 Class 350, or EN 15659 LFS 30 P or 60 P)
  only has to keep the inside below about 177 °C, which a disk will not
  survive working. But Proton holds the main copy: the disk in the safe
  matters only if Proton loses your files in the same month your house
  burns down, so a paper safe is a reasonable home for it. If you want
  the disk itself to survive a fire, look for UL 72 Class 125 or
  EN 1047-1 class DIS.

## Preparing the disks

Do one disk at a time, with only that one plugged in, so that the label on
each case matches the name of its volume. Find the disk:

```sh
diskutil list external physical
```

Note its identifier, such as `disk2`, and check that the size is right:
the next command erases the whole disk.

```sh
diskutil eraseDisk APFS Firesafe-A GPT disk2
```

That makes an APFS container holding a volume `Firesafe-A`. To encrypt it,
find the volume's own identifier, which is not the disk's:

```sh
diskutil info /Volumes/Firesafe-A | grep 'Device Identifier'
diskutil apfs encryptVolume disk3s1 -user disk
```

`encryptVolume` asks for the passphrase. Store it somewhere safe that is
not only the Mac, such as your password manager; without it, the disk in
the fire safe is no use to anyone, including you. Encryption carries on
in the background, quickly on an empty disk;
`diskutil apfs list disk3 | grep -i filevault` says `Yes (Unlocked)` once
it is done.

Eject the disk, then plug it in again while you can see the screen
(through Screen Sharing, for a headless Mac). In the password dialog, tick
**Remember this password in my keychain**, so that it unlocks by itself
from then on. Then:

```sh
proton-firesafe init /Volumes/Firesafe-A
```

Optionally, stop Spotlight from indexing it: `mdutil -i off
/Volumes/Firesafe-A`, with sudo if it refuses.

Then the same for `Firesafe-B`, which can go straight into the safe. Keep
only one disk plugged in from then on: with both attached, proton-firesafe
would keep switching to whichever has the older takeout, and never ask
for a swap.

## Installing

```sh
git clone https://github.com/ableyjoe/proton-firesafe.git
cd proton-firesafe
make install
```

This builds and installs `proton-firesafe`, its launcher and its manual
page under `~/.local`, and a config file in
`~/.config/proton-firesafe/config`. Check `MAILTO` in it; everything else
has sensible defaults, described in `proton-firesafe(1)`.

To install somewhere else, say `make install PREFIX=$HOME/local`, and give
`make agent` the same `PREFIX` later. Run make as yourself, not with
`sudo`: the config file and the agent belong in your home folder.

### Mail

msmtp needs to know how to send mail; put this in `~/.msmtprc` and
`chmod 600` it:

```
defaults
auth on
tls on
tls_starttls on

account default
host smtp.example.net
port 587
from you@example.net
user you@example.net
passwordeval security find-generic-password -s msmtp-proton-firesafe -w
```

Use your mail provider's submission server and login. If it listens on
port 465 instead, set `port 465` and `tls_starttls off`. If it offers
app-specific passwords, make one for this. Keep the password in the
keychain, where `passwordeval` finds it; `security` asks for it, so it
stays out of your shell history:

```sh
security add-generic-password -s msmtp-proton-firesafe -a you@example.net -w
```

Proton Mail offers [SMTP
submission](https://proton.me/support/smtp-submission) only for
custom-domain addresses on paid plans; for a `proton.me` address, Proton
Mail Bridge would do, but it is another program to keep running. Then:

```sh
proton-firesafe test-mail
```

### The daily run

```sh
make agent
```

This installs and starts a launchd agent that runs proton-firesafe at
03:17 every day, a time that happens exactly once a day whatever daylight
saving is doing. (`make agent HOUR=1 MINUTE=45` picks another.) launchd
rather than cron, because cron jobs run outside the login session and so
cannot reach the keychain.

**Before the first run, give the launcher Full Disk Access.** macOS lets a
launchd job use an external disk only if the program responsible for the
job has it, and it does not ask: it just refuses. For a shell script, that
program would be the shell, and granting it would cover every shell script
launchd runs. So the agent runs `proton-firesafe-launch`, a few lines of C
that run the script and wait for it, as cron does for its jobs; the
script's path is compiled in, so the launcher can run nothing else. In
System Settings → Privacy & Security → Full Disk Access, click **+**, press
Cmd-Shift-G, and paste the launcher's path, which `make agent` prints:
`~/.local/libexec/proton-firesafe-launch` by default.

macOS ties that permission to the exact build, so if the launcher is ever
rebuilt (because `PREFIX` changed, or its source did), remove it from the
list and add it again. Without the permission, takeouts fail at once, and
the email about it says so.

Plug in `Firesafe-A`, and rather than waiting for the night, start the
first takeout now and watch it:

```sh
launchctl kickstart gui/$(id -u)/nl.strandkip.proton-firesafe
tail -f ~/Library/Logs/proton-firesafe.log
```

If macOS asks whether `security` may read the msmtp password from the
keychain, the answer is *Always Allow*. A first takeout of hundreds of
gigabytes takes hours, after which you should get an email saying that
`Firesafe-A` is in place. Anything that goes wrong before proton-firesafe
can log it ends up in `~/Library/Logs/proton-firesafe.launchd.log`.

### Watching a takeout

proton-drive shows its progress only on a terminal, so the takeout's own
log stays quiet until the end. To see that it is still going, watch the
folder grow:

```sh
pgrep -lf proton-drive
while true; do date; du -sk /Volumes/Firesafe-A/takeout-*.partial; sleep 30; done
```

How long it takes depends more on how many files you have than on how
big they are. On a gigabit connection, big files came down at 350–450
Mbit/s, but proton-drive fetches only five files at a time, each needing
several round trips, so folders of small files went at about ten files a
second. The first takeout of 500 GB took about 19 hours, nearly all of it
on the small files. Pauses of a few minutes, with the network quiet too,
are normal. After each file, proton-drive reads it back to check its
SHA-1, which for a big file takes a while at a portable disk's speed.

A takeout still running after a day gets you an email. If yours
routinely take that long, raise `TAKEOUT_WARN_HOURS` in the config file.

## Day to day

Mostly, nothing. Every four weeks or so you get an email saying it is time
to swap the backup disks. The attached disk has already been ejected, so
unplug it, put it in the fire safe, and plug in the other one. The next
night's takeout to it is confirmed by email.

Other emails mean something needs a look: a takeout that failed (repeated
daily until one works, usually because `proton-drive` needs logging in
again), a takeout in which some files could not be exported, a takeout
still running after a day, a disk too full or not encrypted, or the disk
you just swapped out plugged back in. If no disk is attached, you hear
about it weekly.

```sh
proton-firesafe status     # what is attached, and what is due when
proton-firesafe takeout    # take out now, whether or not one is due
proton-firesafe eject      # swap early
```

If a swap request is long overdue, proton-firesafe is not running: nobody
is logged in, or the Mac is off. That is the one failure it cannot email
you about. For a weekly "all is well" instead, set `STATUS_EVERY_DAYS=7`.

## Restoring

A takeout is plain files: `my-files/`, `devices/` and `photos/` mirror
your Drive, with `manifest.json` files describing what was exported, and
when. Copy back whatever you need, or upload it to Proton Drive again.

## What it does not do

- `proton-drive` does not export Proton Docs or Sheets yet. Export those
  from the web app now and then if they matter.
- Every takeout is a full download; there are no increments.
- A takeout on the disk is decrypted. Anyone with the disk and its
  password can read everything on it, which is why both matter.

## Testing

```sh
make test    # runs the script through simulated months, with stand-ins
make lint    # shellcheck, the compiler, mandoc and plutil
```

The tests need nothing from macOS: `tests/stubs` stands in for
`proton-drive`, `caffeinate`, `diskutil`, `msmtp` and `df`, and the
launcher is built against a stand-in script.

## Licence

ISC; see [LICENSE](LICENSE).
