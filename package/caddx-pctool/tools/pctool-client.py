#!/usr/bin/env python3
"""Speak the CADDX PC tool's USB-serial upgrade protocol, the way CADDX_PCTool does.

Works against a stock air unit (ar_fpvhs_upgrade) and against OpenIPC's pctoold
(this package) over the air's CDC-ACM port, so pctoold can be tested from Linux
without Windows. Protocol: ../README.md.

    pctool-client.py info  /dev/ttyACM0
    pctool-client.py flash /dev/ttyACM0 Ascent_H_Sky_18_21_10_OpenIPC_xxxxxxx.img
    pctool-client.py rndis /dev/ttyACM0     # leave updater mode, back to RNDIS

Standard library only.
"""
import argparse
import hashlib
import os
import select
import struct
import sys
import termios
import time
import tty
import zlib

MAGIC = 0x4152544F
DIR_HOST = 0x00010CDC
DIR_DEV = 0x00020CDC
TAG_HOST = 0xABCD0000
FMT = 2
HDR = struct.Struct('<9I')

CMD_REBOOT, CMD_RNDIS, CMD_INFO, CMD_CONNECT = 0x03, 0x3A, 0x3C, 0x72
CMD_START, CMD_DATA, CMD_DONE, CMD_STATUS = 0x73, 0x74, 0x75, 0x76
ST_DONE, ST_FAILED = 3, 4

# What CADDX_PCTool waits after the "clean" reboot request before reconnecting.
RECONNECT_DELAY = 11.5
# Roughly where CADDX_PCTool gives up polling the status.
MAX_POLLS = 200


class ProtocolError(Exception):
    pass


def cstr(b):
    return b.split(b'\0', 1)[0].decode(errors='replace')


class Port:
    def __init__(self, path=None, fd=None):
        self.path = path
        self.fd = fd
        self.seq = 0
        if fd is None:
            self.open()

    def open(self, wait=0.0):
        deadline = time.monotonic() + wait
        while True:
            try:
                self.fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)
        tty.setraw(self.fd)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def close(self):
        if self.path is not None and self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def reconnect(self, delay):
        """Like the PC tool: close, wait, reopen whatever port shows up again."""
        if self.path is None:
            time.sleep(min(delay, 1.0))
            return
        self.close()
        time.sleep(delay)
        self.open(wait=30.0)

    def _read_exact(self, n, timeout):
        buf = b''
        deadline = time.monotonic() + timeout
        while len(buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise ProtocolError('timeout waiting for %d bytes (got %d)' % (n, len(buf)))
            r, _, _ = select.select([self.fd], [], [], left)
            if r:
                chunk = os.read(self.fd, n - len(buf))
                if not chunk:
                    raise ProtocolError('port closed')
                buf += chunk
        return buf

    def _write(self, data):
        view = memoryview(data)
        while view:
            n = os.write(self.fd, view)
            view = view[n:]

    def request(self, cmd, payload=b'', timeout=5.0):
        seq = self.seq
        self.seq += 1
        hdr = HDR.pack(MAGIC, DIR_HOST, TAG_HOST, cmd, FMT, len(payload), seq, 0, 0)
        crc = zlib.crc32(hdr + payload)
        hdr = HDR.pack(MAGIC, DIR_HOST, TAG_HOST, cmd, FMT, len(payload), seq, 0, crc)
        # The PC tool sends header and payload as two separate USB writes.
        self._write(hdr)
        if payload:
            self._write(payload)

        # Sync on the magic, then header, then payload.
        win = self._read_exact(4, timeout)
        while struct.unpack('<I', win)[0] != MAGIC:
            win = win[1:] + self._read_exact(1, timeout)
        rest = self._read_exact(HDR.size - 4, timeout)
        f = HDR.unpack(win + rest)
        body = self._read_exact(f[5], timeout)
        zeroed = HDR.pack(*f[:8], 0)
        if zlib.crc32(zeroed + body) != f[8]:
            raise ProtocolError('reply to 0x%02x: bad crc' % cmd)
        if f[1] != DIR_DEV or f[3] != cmd or f[6] != seq:
            raise ProtocolError('reply mismatch: dir 0x%x cmd 0x%02x seq %d (sent 0x%02x seq %d)'
                                % (f[1], f[3], f[6], cmd, seq))
        return body


def check_result(cmd, body, status_off):
    result = struct.unpack_from('<I', body, 0)[0]
    status = cstr(body[status_off:status_off + 64])
    if result != 0 or status != 'OK':
        raise ProtocolError('cmd 0x%02x refused: result %d, "%s"' % (cmd, result, status))


def info(port):
    b = port.request(CMD_INFO)
    if len(b) != 300:
        raise ProtocolError('info reply is %d bytes, expected 300' % len(b))
    d = {
        'max_chunk': struct.unpack_from('<I', b, 0x00)[0],
        'name': cstr(b[0x24:0x64]),
        'temp': struct.unpack_from('<i', b, 0x64)[0],
        'fw': cstr(b[0x68:0xA8]),
        'sn': cstr(b[0xA8:0xC8]),
        'hw': cstr(b[0xC8:0xE8]),
        'status': cstr(b[0xEC:0x12C]),
    }
    return d


def flash(port, image, reconnect_delay, poll_interval):
    data = open(image, 'rb').read()
    md5 = hashlib.md5(data).hexdigest()
    dev = info(port)
    print('device: %(name)s fw=%(fw)s hw=%(hw)s sn=%(sn)s temp=%(temp)d' % dev)
    chunk = dev['max_chunk'] or 0x100000

    b = port.request(CMD_REBOOT, b'clean'.ljust(32, b'\0'))
    check_result(CMD_REBOOT, b, 4)
    print('reboot to clean system acknowledged, reconnecting in %.1f s' % reconnect_delay)
    port.reconnect(reconnect_delay)

    check_result(CMD_CONNECT, port.request(CMD_CONNECT), 4)

    start = bytearray(328)
    start[0:32] = md5.encode()
    struct.pack_into('<II', start, 0x40, len(data), 1)
    name = os.path.basename(image).encode()[:100]
    start[0x48:0x48 + len(name) + 8] = b'/tmp/pc/' + name
    host_path = os.path.abspath(image).encode()[:127]
    start[0xC8:0xC8 + len(host_path)] = host_path
    check_result(CMD_START, port.request(CMD_START, bytes(start)), 4)

    t0 = time.monotonic()
    for off in range(0, len(data), chunk):
        b = port.request(CMD_DATA, data[off:off + chunk], timeout=30.0)
        check_result(CMD_DATA, b, 16)
        received = struct.unpack_from('<I', b, 4)[0]
        print('\rsent %d/%d' % (received, len(data)), end='', flush=True)
    dt = time.monotonic() - t0
    print('\nupload done in %.1f s (%.1f MB/s)' % (dt, len(data) / dt / 1e6))
    check_result(CMD_DONE, port.request(CMD_DONE, timeout=30.0), 16)

    for _ in range(MAX_POLLS):
        time.sleep(poll_interval)
        b = port.request(CMD_STATUS)
        percent, state = struct.unpack_from('<II', b, 0)
        print('\rprogress %3d%% state %d %s' % (percent, state, cstr(b[8:72])), end='', flush=True)
        if state == ST_DONE:
            print('\nupgrade done, device reboots')
            return 0
        if state == ST_FAILED:
            print('\nupgrade FAILED')
            return 1
    print('\ngave up after %d polls' % MAX_POLLS)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('action', choices=['info', 'flash', 'rndis'])
    ap.add_argument('port', help='serial port, e.g. /dev/ttyACM0')
    ap.add_argument('image', nargs='?', help='ASW image (flash)')
    ap.add_argument('--reconnect-delay', type=float, default=RECONNECT_DELAY)
    ap.add_argument('--poll-interval', type=float, default=0.8)
    a = ap.parse_args()

    port = Port(a.port)
    try:
        if a.action == 'info':
            for k, v in info(port).items():
                print('%-9s %s' % (k, v))
            return 0
        if a.action == 'rndis':
            check_result(CMD_RNDIS, port.request(CMD_RNDIS), 4)
            print('switching to RNDIS')
            return 0
        if not a.image:
            ap.error('flash needs an image')
        return flash(port, a.image, a.reconnect_delay, a.poll_interval)
    except ProtocolError as e:
        print('\nerror: %s' % e, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
