#!/usr/bin/env python3
"""Exercise the actual terminal: timers, live code reload, drag/resize, and cleanup."""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/haunt"


def widget(initial, following):
    return f"""local h = require('haunt')
return h.widget {{
  title = 'Smoke',
  setup = function(ctx)
    local value = '{initial}'
    local cancel = ctx:every(250, function() value = '{following}'; ctx:update() end)
    return function()
      return h.ui.text {{
        value,
        onMouseDown = function() cancel(); value = 'EEEEEEEE'; ctx:update() end,
        onKeyDown = function(event)
          if event.name == 'z' then cancel(); value = 'FFFFFFFF'; ctx:update() end
        end,
      }}
    end
  end,
}}
"""


def main():
    location = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="haunt-smoke-", dir=location) as directory:
        directory = Path(directory)
        source = directory / "widget.lua"
        source.write_text(widget("AAAAAAAA", "BBBBBBBB"))
        layout = directory / "layout.json"
        layout.write_text(json.dumps({
            "version": 1, "id": "smoke", "name": "Smoke",
            "grid": {"columns": 12, "rows": 12},
            "widgets": [{"id": "smoke", "widget": "widget.lua", "options": {},
                         "rect": {"x": 0, "y": 0, "width": 6, "height": 6}}],
        }))
        preview = subprocess.run([BINARY, layout, "--snapshot", "80x24"], capture_output=True, timeout=10)
        assert preview.returncode == 0, preview.stderr.decode(errors="replace")
        assert preview.stdout.startswith(b"AAAAAAAA"), 'content must start at terminal cell (0, 0)'
        assert preview.stdout.splitlines()[-1].strip() == b''
        assert b"haunt" not in preview.stdout and b"Smoke" not in preview.stdout and b"quit" not in preview.stdout
        assert '╭' not in preview.stdout.decode(), 'normal presentation should be borderless'

        bordered = json.loads(layout.read_text())
        bordered['appearance'] = {'borders': True}
        layout.write_text(json.dumps(bordered))
        border_preview = subprocess.run([BINARY, layout, '--snapshot', '80x24'], capture_output=True, timeout=10)
        assert border_preview.returncode == 0, border_preview.stderr.decode(errors='replace')
        assert '╭' in border_preview.stdout.decode()
        assert b'Smoke' not in border_preview.stdout, 'optional frames should not add widget title bars'
        bordered['appearance']['borders'] = False
        layout.write_text(json.dumps(bordered))

        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 25, 80, 0, 0))
        process = subprocess.Popen([BINARY, layout], stdin=slave, stdout=slave, stderr=slave,
                                   env={**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor"})
        received = bytearray()

        def until(predicate, seconds=4):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if predicate():
                    return
                assert process.poll() is None, received.decode(errors="replace")
                readable, _, _ = select.select([master], [], [], 0.05)
                if readable:
                    received.extend(os.read(master, 65536))
            raise AssertionError(received.decode(errors="replace"))

        try:
            until(lambda: b"AAAAAAAA" in received)
            until(lambda: b"BBBBBBBB" in received)
            received.clear()
            source.write_text(widget("CCCCCCCC", "CCCCCCCC"))
            until(lambda: b"CCCCCCCC" in received)
            received.clear()
            source.write_text("this is not valid Lua!!!")
            os.write(master, b'e')
            until(lambda: b"Widget error" in received)
            assert process.poll() is None
            received.clear()
            source.write_text(widget("DDDDDDDD", "DDDDDDDD"))
            os.write(master, b'e')
            until(lambda: b"DDDDDDDD" in received)

            received.clear()
            os.write(master, b"\x1b[<0;3;4M\x1b[<0;3;4m")
            until(lambda: b"EEEEEEEE" in received)
            received.clear()
            os.write(master, b"z")
            until(lambda: b"FFFFFFFF" in received)

            # Edit mode owns gestures; normal content remains interactive.
            os.write(master, b'e')
            os.write(master, b"\x1b[<0;3;3M\x1b[<32;23;7M\x1b[<0;23;7m")
            until(lambda: json.loads(layout.read_text())["widgets"][0]["rect"]["x"] == 3)
            assert json.loads(layout.read_text())['widgets'][0]['rect']['y'] == 2
            # Regression: move back to the physical top-left on an uneven 25-row viewport.
            os.write(master, b"\x1b[<0;23;6M\x1b[<32;1;1M\x1b[<0;1;1m")
            until(lambda: json.loads(layout.read_text())["widgets"][0]["rect"]["y"] == 0)
            assert json.loads(layout.read_text())['widgets'][0]['rect']['x'] == 0
            # Resize to the bottom-right: all terminal rows and columns are usable.
            os.write(master, b"\x1b[<0;40;12M\x1b[<32;80;25M\x1b[<0;80;25m")
            until(lambda: json.loads(layout.read_text())["widgets"][0]["rect"]["height"] == 12)
            assert json.loads(layout.read_text())['widgets'][0]['rect']['width'] == 12

            os.write(master, b'b')
            until(lambda: json.loads(layout.read_text())['appearance']['borders'])
            os.write(master, b'b')
            until(lambda: not json.loads(layout.read_text())['appearance']['borders'])
            received.clear()
            os.write(master, b'e')
            until(lambda: b'FFFFFFFF' in received)

            saved = json.loads(layout.read_text())
            received.clear()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
            process.send_signal(signal.SIGWINCH)
            until(lambda: b"FFFFFFFF" in received)
            assert json.loads(layout.read_text()) == saved
            os.write(master, b"q")
            assert process.wait(timeout=5) == 0
            assert termios.tcgetattr(slave) == original, "terminal modes were not restored"
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)
    print("PTY smoke passed: content-only canvas, optional frames, reload recovery, input, all-edge drag/resize, persistence and terminal restoration")


if __name__ == "__main__":
    main()
