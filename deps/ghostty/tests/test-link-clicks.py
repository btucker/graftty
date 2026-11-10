#!/usr/bin/env python3
"""Run real native mouse callbacks in disposable subprocesses, never the installed app."""
import argparse
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=Path)
    parser.add_argument("fixture_generator", type=Path)
    parser.add_argument("--case")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="graftty-link-click-") as directory:
        root = Path(directory)
        (root / "README.md").write_text("native link fixture\n")
        spaced = root / "with spaces"
        spaced.mkdir()
        (spaced / "README.md").write_text("encoded directory fixture\n")
        kitty = root / "kitty #?%20"
        kitty.mkdir()
        (kitty / "README.md").write_text("raw directory fixture\n")
        uri = "file://localhost" + quote(str(root))
        path = str(root / "README.md")
        relative = "./README.md"
        osc = lambda pwd: "\x1b]7;" + pwd + "\x07"
        link = lambda url: "\x1b]8;;" + url + "\x07README.md\x1b]8;;\x07"
        # name, raw producer PWD, visible VT, expected callback URL, URL kind, gesture
        cases = [
            ("snapshot-file-uri", uri, relative, path, 0, "click"),
            ("snapshot-absolute-pwd", str(root), relative, path, 0, "click"),
            ("snapshot-percent-encoded", "file://localhost" + quote(str(spaced)), relative,
             str(spaced / "README.md"), 0, "click"),
            ("snapshot-kitty-raw", "kitty-shell-cwd://localhost" + str(kitty), relative,
             str(kitty / "README.md"), 0, "click"),
            ("snapshot-absolute-link", uri, path, path, 0, "click"),
            ("snapshot-osc8-absolute", uri, link("file://" + path), "file://" + path, 3, "click"),
            ("snapshot-osc8-relative", uri, link(relative), relative, 3, "click"),
            ("snapshot-empty-pwd", "", relative, relative, 0, "click"),
            ("snapshot-relative-pwd", "relative/directory", relative, relative, 0, "click"),
            ("snapshot-malformed-pwd", "file://[", relative, relative, 0, "click"),
            ("snapshot-unsupported-scheme", "https://localhost" + str(root), relative, relative, 0, "click"),
            ("snapshot-foreign-host", "file://not-this-host.invalid" + str(root), relative, relative, 0, "click"),
            ("snapshot-missing-host", "file://" + str(root), relative, relative, 0, "click"),
            ("snapshot-empty-uri-path", "file://localhost", relative, relative, 0, "click"),
            ("snapshot-missing-file", uri, "./missing/README.md", "./missing/README.md", 0, "click"),
            ("snapshot-prompt", uri, "\x1b]133;A\x07\x1b]133;B\x07" + relative, path, 0, "click"),
            ("snapshot-history", uri, "history\r\n" * 500 + "\x1b[2J\x1b[H" + relative, path, 0, "click"),
            ("snapshot-drag", uri, relative, path, 0, "drag"),
            ("live-file-uri", uri, relative, path, 0, "live"),
            ("live-osc8", uri, link("file://" + path), "file://" + path, 3, "live"),
        ]
        if args.case:
            cases = [case for case in cases if case[0] == args.case]
            if not cases:
                parser.error("unknown case")
        failed = []
        for name, pwd, visible, expected, kind, gesture in cases:
            data = osc(pwd) + visible
            fixture = root / (name + ".bin")
            subprocess.run([str(args.fixture_generator), str(fixture), data], check=True, timeout=20)
            command = [str(args.probe), str(fixture), expected, str(kind), gesture]
            if gesture == "live":
                command.append(data)
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=20)
                passed = result.returncode == 0 and "native link click PASS" in result.stdout
                if not passed:
                    print(result.stdout + result.stderr, flush=True)
            except subprocess.TimeoutExpired:
                passed = False
                print(f"{name}: timed out", flush=True)
            print(f"{name}: {'PASS' if passed else 'FAIL'}", flush=True)
            if not passed:
                failed.append(name)
        if failed:
            raise SystemExit("Failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
