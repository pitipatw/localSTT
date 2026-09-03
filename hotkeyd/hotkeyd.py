#!/usr/bin/env python3
"""hotkeyd: F13 press/release on any keyboard -> "start"/"stop" lines on a UNIX socket.
Runs as the system user `hotkeyd`, the only account in group `input`, so your own session never
gets keyboard-read access. Reads /dev/input, writes the socket, never reads the socket. Hard cap
of 80 lines, stdlib only: anything added here is attack surface. See docs/feature-requests/02.
"""
import fcntl, glob, os, select, socket, struct, time

EVENT_FMT = "llHHi"                      # struct input_event on x86_64: tv_sec, tv_usec, type, code, value
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY, KEY_F13, PRESS, RELEASE = 1, 183, 1, 0                          # value 2 = autorepeat, ignored
EVIOCGBIT_EV_KEY = 0x80000000 | (96 << 16) | (ord("E") << 8) | 0x21   # _IOR('E', 0x20+EV_KEY, 96-byte key bitmap)
SOCK = os.environ.get("HOTKEYD_SOCKET", "/run/hotkeyd/hotkey.sock")
MAX_HOLD_S = float(os.environ.get("HOTKEYD_MAX_HOLD_S", "60"))

class HoldTracker:
    """Press/release state machine with a hold cap. feed() returns the lines to emit; call it
    with an empty buffer on a timer so the cap fires even when the keyboard stays silent."""
    def __init__(self, max_hold_s=MAX_HOLD_S):
        self.max_hold_s, self.down_since = max_hold_s, None
    def feed(self, buf, now):
        out = []
        if self.down_since is not None and now - self.down_since >= self.max_hold_s:
            self.down_since = None       # stuck key or something resting on it: stop now, ignore the late release
            out.append("stop")
        for _, _, etype, code, value in struct.iter_unpack(EVENT_FMT, buf):
            ours = etype == EV_KEY and code == KEY_F13   # any other key is dropped before it is looked at
            if ours and value == PRESS and self.down_since is None:
                self.down_since = now
                out.append("start")
            elif ours and value == RELEASE and self.down_since is not None:
                self.down_since = None
                out.append("stop")
        return out

def open_keyboards(keyboards):
    """Open every /dev/input/event* that advertises KEY_F13 and is not open yet (mice etc. are skipped)."""
    for path in set(glob.glob("/dev/input/event*")) - keyboards.keys():
        try:
            fd, bits = os.open(path, os.O_RDONLY), bytearray(96)
            fcntl.ioctl(fd, EVIOCGBIT_EV_KEY, bits)
            if bits[KEY_F13 // 8] & (1 << (KEY_F13 % 8)):
                keyboards[path] = fd
            else:
                os.close(fd)
        except OSError:
            pass

def main():
    os.umask(0o117)                      # socket is created 0660: owner + the (setgid) directory's group
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCK)
    server.listen(4)
    clients, keyboards, tracker, next_scan = [], {}, HoldTracker(), 0.0
    while True:
        now = time.monotonic()
        if now >= next_scan:
            open_keyboards(keyboards)
            next_scan = now + 5.0    # hotplug: look for new keyboards every 5 s
        readable = select.select([server, *keyboards.values()], [], [], 0.5)[0]   # blocking reads are safe after select
        lines = tracker.feed(b"", now)
        for fd in readable:
            if fd is server:
                clients.append(server.accept()[0])
                continue
            try:
                lines += tracker.feed(os.read(fd, EVENT_SIZE * 64), now)
            except OSError:              # unplugged: forget it; a rescan re-opens it if it comes back
                keyboards = {p: f for p, f in keyboards.items() if f != fd}
                os.close(fd)
        for line in lines:
            for client in clients[:]:
                try:
                    client.sendall(f"{line}\n".encode())
                except OSError:          # relay went away; it reconnects when systemd restarts it
                    clients.remove(client)
                    client.close()

if __name__ == "__main__":
    main()
