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
proton-firesafe will not write a takeout anywhere else. The emails never
name your files: the takeout's own output, which does, is kept on the
encrypted disk.

## What you need

- **A Mac that stays on and logged in**, such as a Mac mini in a cupboard.
  The agent runs in your login session, because `proton-drive` keeps its
  session, and macOS keeps the disks' passwords, in the login keychain.
  Turn on automatic login so it comes back after a power cut.
- **proton-drive**, Proton's command-line client: `port install
  proton-drive-cli`, or Proton's own download. Log it in once with
  `proton-drive auth login`.
- **msmtp**, to send the emails: `port install msmtp`.
- **Two identical external disks**, each with room for two takeouts and a
  third in progress. With 500 GB in Proton Drive, 2 TB disks will do, with
  some room for growth. A spinning disk is fine: the takeout runs at the
  speed of your internet connection, not of the disk. Label them A and B.
- **A fire safe rated for data**, not just for paper. A safe made for paper
  (UL 72 Class 350, or EN 15659 LFS 30 P or 60 P) only has to keep the
  inside below about 177 °C, which paper survives and disks do not. Look
  for UL 72 Class 125, which keeps the inside below 52 °C, or EN 1047-1
  class DIS, or a data insert for a paper safe.

## Preparing the disks

On the Mac, for each disk in turn. Find the disk, erase it as a single
APFS volume, and encrypt it:

```sh
diskutil list external
diskutil eraseDisk APFS Firesafe-A GPT disk4    # the disk from the list
diskutil apfs encryptVolume /Volumes/Firesafe-A -user disk -passprompt
```

(Disk Utility's *Erase*, with format *APFS (Encrypted)* and scheme *GUID
Partition Map*, does the same.) Store the password somewhere safe that is
not only the Mac, such as your password manager. Without it, the disk in
the fire safe is no use to anyone, including you.

Eject the disk, then plug it in again while you can see the screen
(through Screen Sharing, for a headless Mac). In the password dialog, tick
**Remember this password in my keychain**, so that it unlocks by itself
from then on. Then:

```sh
proton-firesafe init /Volumes/Firesafe-A
```

Optionally, stop Spotlight from indexing it: `sudo mdutil -i off
/Volumes/Firesafe-A`.

## Installing

```sh
git clone https://github.com/ableyjoe/proton-firesafe.git
cd proton-firesafe
make install          # into ~/.local; or make install PREFIX=/usr/local
```

This installs `proton-firesafe`, its manual page, and a config file in
`~/.config/proton-firesafe/config`. Check `MAILTO` in it; everything else
has sensible defaults, described in `proton-firesafe(1)`.

### Mail

msmtp needs to know how to send mail; put this in `~/.msmtprc` and
`chmod 600` it:

```
defaults
auth on
tls on
tls_starttls on

account default
host smtp.protonmail.ch
port 587
from jabley@strandkip.nl
user jabley@strandkip.nl
passwordeval security find-generic-password -s msmtp-proton-firesafe -w
```

That is for Proton Mail with a custom domain, which offers [SMTP
submission](https://proton.me/support/smtp-submission) on paid plans:
generate an SMTP token in *Settings → All settings → IMAP/SMTP → SMTP
tokens*, and keep it in the keychain, where `passwordeval` finds it:

```sh
security add-generic-password -s msmtp-proton-firesafe -a jabley@strandkip.nl -w
```

Any other SMTP server works the same way. Then:

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

Plug in `Firesafe-A`, and rather than waiting for the night, start the
first takeout now and watch it:

```sh
launchctl kickstart gui/$(id -u)/nl.strandkip.proton-firesafe
tail -f ~/Library/Logs/proton-firesafe.log
```

Do this while you can see the screen, because macOS asks two questions,
once, and waits for the answers: whether `sh` may access files on a
removable volume (*Allow*), and whether `security` may read the msmtp
password from the keychain (*Always Allow*). Unanswered, at 03:17 on a
headless Mac, they would hold the takeout up indefinitely; if that ever
happens, a takeout still running after a day gets you an email.

A first takeout of hundreds of gigabytes takes hours, after which you
should get an email saying that `Firesafe-A` is in place.

## Day to day

Mostly, nothing. Every four weeks or so you get an email saying it is time
to swap the backup disks. The attached disk has already been ejected, so
unplug it, put it in the fire safe, and plug in the other one. The next
night's takeout to it is confirmed by email.

Other emails mean something needs a look: a takeout that failed (repeated
daily until one works, usually because `proton-drive` needs logging in
again), a takeout in which some files could not be exported, a disk too
full or not encrypted, or the disk you just swapped out plugged back in.
If no disk is attached, you hear about it weekly.

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
make lint    # shellcheck, mandoc and plutil
```

The tests need nothing from macOS: `tests/stubs` stands in for
`proton-drive`, `caffeinate`, `diskutil`, `msmtp` and `df`.

## Licence

ISC; see [LICENSE](LICENSE).
