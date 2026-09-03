# Feature request: hold-to-talk WITHOUT putting the user in the `input` group

**Status: implemented** — `hotkeyd/hotkeyd.py`, `hotkeyd/hotkey-relay`, `systemd/hotkeyd.service`, `systemd/hotkey-relay.service`, `install.sh` `step_hotkeyd`, `tests/test_hotkeyd.py`; documented in INSTALL.md §1.2. Deviation from the sketch below: the socket directory is made setgid-`<user>` by a root `ExecStartPre` so the socket inherits the group without adding you to a `hotkeyd` group (no re-login).

**Why.** Push-to-talk currently requires the user's account to be in `input`, which lets every
process running as that user read every keystroke (SECURITY_REVIEW.md H2, INSTALL.md §1.2). That is
why toggle mode is now the default. This proposal restores the hold-to-talk feel while keeping the
user *out* of `input`: the keyboard-reading privilege moves to a tiny dedicated system user whose
only process is small enough to audit in a minute.

**Design.**

```
/dev/input/event*  ──read──▶  hotkeyd  (system user `hotkeyd`, group `input`, sandboxed)
                                 │  writes one line per transition: "start\n" / "stop\n"
                                 ▼
                    /run/hotkeyd/hotkey.sock   (owner hotkeyd, group <your user>, mode 0640 dir / 0660 sock)
                                 │  one-directional: hotkeyd never reads from the socket
                                 ▼
                    hotkey-relay (user service, runs as YOU, NOT in `input`)
                                 │  exec: voxtype record start | voxtype record stop
                                 ▼
                    voxtype daemon (user service, unchanged; [hotkey] enabled = false)
```

- `hotkeyd`: ~50 lines of stdlib Python. Opens every `/dev/input/event*` that advertises `EV_KEY`
  with `KEY_F13` (code 183) — use `EVIOCGBIT` via `fcntl.ioctl`, or simply read all and filter —
  decodes 24-byte `struct input_event` (`llHHi` on x86_64), emits `start` on value 1 (press) and
  `stop` on value 0 (release). Ignores every other key code *before* doing anything with the event.
  Never logs key codes. Hard cap: emits `stop` on its own if the key has been down for
  `MAX_HOLD_S` (default 60). Re-scans devices on hotplug (inotify on `/dev/input`, or a 5 s rescan).
- `hotkey-relay`: ~20 lines. Connects to the socket, reads lines, runs `voxtype record start|stop`
  with a 2 s timeout, drops anything that is not exactly `start` or `stop`. If the socket vanishes,
  it exits and systemd restarts it; while it is down, holding F13 does nothing (fail-safe: the mic
  never turns on without the relay).
- Voxtype config: the toggle template (`[hotkey] enabled = false`) — Voxtype no longer listens to the
  keyboard at all; it is driven purely by `voxtype record start|stop`.

**Sandbox for `hotkeyd` (systemd system unit).**
```
User=hotkeyd
Group=hotkeyd
SupplementaryGroups=input
RuntimeDirectory=hotkeyd
RuntimeDirectoryMode=0750          # + chgrp <user> at start, or use SupplementaryGroups on the relay side
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateNetwork=yes                 # no network namespace at all
RestrictAddressFamilies=AF_UNIX
DevicePolicy=closed
DeviceAllow=char-input r           # /dev/input/* read-only
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallArchitectures=native
MemoryDenyWriteExecute=yes
```

**Threat model check.**
- Compromise *as the user*: cannot read the keyboard (not in `input`); can only observe
  start/stop transitions on the socket, i.e. "the user is dictating now". Acceptable.
- Compromise *of hotkeyd*: it can read the keyboard — same as today's push-to-talk — but it has no
  network, no home, no writable filesystem beyond `/run/hotkeyd`, and no input channel an attacker
  could reach it through (it reads only from `/dev/input`). Attack surface ≈ the 50 lines + the
  Python interpreter's evdev struct parsing.
- The socket is write-by-daemon, read-by-user only; the relay validates the two allowed tokens.
- `uinput` group for pasting is unchanged (needed for ydotool in every mode).

**Trade-offs.**
- One more system user, service, and directory; a few more `sudo` lines in `install.sh`.
- A component that must stay tiny forever. Any "feature" added to `hotkeyd` (multiple keys,
  chords, logging, config reload) erodes the audit story — reject such PRs.
- ~1–3 ms extra latency (socket + `voxtype record` exec) on press and release. Not perceptible.
- If the relay is down, hold-to-talk silently does nothing; pair with the recording indicator
  (feature request 01) so the user can tell.

**Installer.** New step `hotkeyd` selected by `HOTKEY_MODE=push_to_talk` (which then no longer
touches the `input` group at all — `I_ACCEPT_INPUT_GROUP` becomes unnecessary and is removed).
Idempotent: creates user/group, installs `/usr/local/lib/hotkeyd/hotkeyd.py` (mode 0755, root-owned,
so the daemon cannot modify its own code), the system unit, the user relay unit, and verifies with
`systemctl is-active hotkeyd` + a synthetic press if `evemu` is available.

**Definition of done.**
- `id -nG` for the user does NOT contain `input`; holding F13 records, releasing pastes.
- `systemd-analyze security hotkeyd` scores under 3.
- `hotkeyd.py` ≤ 80 lines, stdlib only, with a unit test for the event decoder and the
  press/release/cap state machine (feed it synthetic `input_event` bytes).
- Documented in INSTALL.md §1.2 as the recommended way to get hold-to-talk; the `input`-group
  path and `I_ACCEPT_INPUT_GROUP` are removed from `install.sh`.
