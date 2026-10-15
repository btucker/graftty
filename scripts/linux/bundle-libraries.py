#!/usr/bin/env python3
"""Copy the executable's shared-library closure, leaving Ubuntu's glibc in place."""
import argparse
from collections import deque
from pathlib import Path
import re
import shutil
import subprocess

# Loading a bundled glibc against the machine's loader breaks ABI compatibility.
SYSTEM_LIBRARIES = re.compile(r"^(?:ld-linux[^/]*|lib(?:c|m|pthread|dl|rt|resolv|util)\.so(?:\..*)?)$")

def dependencies(binary: Path) -> list[tuple[str, Path]]:
    output = subprocess.run(["ldd", str(binary)], check=False, text=True, capture_output=True)
    if output.returncode and "not a dynamic executable" not in output.stderr + output.stdout:
        raise RuntimeError(output.stderr or output.stdout)
    result = []
    for line in output.stdout.splitlines():
        if "=> not found" in line:
            raise RuntimeError(f"Unresolved library in {binary}: {line.strip()}")
        match = re.match(r"\s*(\S+)\s+=>\s+(/\S+)\s+\(", line)
        if match:
            result.append((Path(match[1]).name, Path(match[2])))
    return result

def bundle(binaries: list[Path], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    pending = deque(binaries)
    seen = set()
    while pending:
        binary = pending.popleft()
        for name, library in dependencies(binary):
            if name in seen or SYSTEM_LIBRARIES.match(name):
                continue
            if Path(name).name != name:
                raise RuntimeError(f"Invalid library name: {name}")
            seen.add(name)
            shutil.copy2(library.resolve(strict=True), destination / name)
            pending.append(library)
    if not any(name.startswith("libswiftCore.so") for name in seen):
        raise RuntimeError("No Swift runtime libraries found in the executable dependency closure")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("binaries", nargs="+", type=Path)
    arguments = parser.parse_args()
    bundle(arguments.binaries, arguments.destination)
