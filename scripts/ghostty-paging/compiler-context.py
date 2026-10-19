#!/usr/bin/env python3
"""Read the manifest's renderer context for flags applied to dependency targets too."""
import json
import subprocess
import sys


def compiler_context(manifest):
    target = next(target for target in manifest["targets"] if target["name"] == "Graftty")
    for setting in target["settings"]:
        for flag in setting.get("kind", {}).get("unsafeFlags", {}).get("_0", []):
            if flag.startswith("-DGRAFTTY_RENDERER_"):
                return flag
    raise ValueError("Package.swift did not supply a renderer compiler context")


if __name__ == "__main__":
    repository, scratch = sys.argv[1:]
    result = subprocess.run(["swift", "package", "--package-path", repository,
                             "--scratch-path", scratch, "--manifest-cache", "none", "dump-package"],
                            stdout=subprocess.PIPE, text=True, check=True)
    print(compiler_context(json.loads(result.stdout)))
