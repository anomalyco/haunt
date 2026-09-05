#!/usr/bin/env python3
"""Fetch the pinned native development toolchain. No runtime dependencies on Python."""

import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get("HAUNT_DOWNLOAD_CACHE", ROOT / ".cache/downloads"))
OPENTUI = "7581976f4d2c917fd5ae5266c8bc61f0e44fc933"
ZIG = "0.16.0"
ZIG_HASHES = {
    "x86_64-linux": "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
    "aarch64-linux": "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
    "x86_64-macos": "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
    "aarch64-macos": "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
}


def install(name, url, digest, destination, pin):
    marker = destination / ".haunt-pin"
    if marker.exists() and marker.read_text() == pin:
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / name
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        print(f"Downloading {name}", flush=True)
        partial = archive.with_suffix(archive.suffix + ".part")
        urllib.request.urlretrieve(url, partial)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != digest:
            partial.unlink()
            raise RuntimeError(f"Checksum mismatch: {name}")
        partial.replace(archive)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        with tarfile.open(archive) as package:
            package.extractall(temporary, filter="data")
        entries = list(Path(temporary).iterdir())
        if len(entries) != 1 or not entries[0].is_dir():
            raise RuntimeError(f"Unexpected archive layout: {name}")
        if destination.exists():
            shutil.rmtree(destination)
        entries[0].replace(destination)
    marker.write_text(pin)


def main():
    arch = {"arm64": "aarch64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    system = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    target = f"{arch}-{system}"
    if target not in ZIG_HASHES:
        raise SystemExit(f"Native bootstrap does not yet support {target}")
    archive = f"zig-{target}-{ZIG}.tar.xz"
    install(archive, f"https://ziglang.org/download/{ZIG}/{archive}", ZIG_HASHES[target], ROOT / ".tools/zig", ZIG + target)
    install("opentui.tar.gz", f"https://codeload.github.com/anomalyco/opentui/tar.gz/{OPENTUI}",
            "fe3429d4359d9689a6f1225cb50b14769c8f84fe98ede470b72418027adb7368", ROOT / ".deps/opentui", OPENTUI)
    install("lua.tar.gz", "https://www.lua.org/ftp/lua-5.4.9.tar.gz",
            "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6", ROOT / ".deps/lua", "5.4.9")
    native = ROOT / ".deps/opentui/packages/native"
    if not (native / "zig-deps/.ready").exists():
        subprocess.run(["sh", "scripts/prepare-zig-deps.sh"], cwd=native, check=True)


if __name__ == "__main__":
    main()
