#!/usr/bin/env python3
"""Offline invocation contract; fake archives here are never engine proof."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidBuilderInvocationTests(unittest.TestCase):
    def test_unrelated_cwd_builds_each_crate_target(self):
        with tempfile.TemporaryDirectory(prefix="reckless builder ") as temporary:
            root = Path(temporary).resolve()
            repo = root / "repository with spaces"
            (repo / "Tools").mkdir(parents=True)
            (repo / "rust").mkdir()
            (repo / "rust" / "Cargo.toml").write_text("[package]\nname='fixture'\n")
            script = repo / "Tools" / "build-android.sh"
            shutil.copyfile(Path(__file__).resolve().parents[1] / script.name, script)
            cargo_home = root / "cargo home"
            (cargo_home / "bin").mkdir(parents=True)
            rustup = cargo_home / "bin" / "rustup"
            rustup.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:1] in (["toolchain"], ["target"]):
    sys.exit(0)
assert args[:4] == ["run", "1.96.1", "cargo", "ndk"], args
if args[4:] == ["--version"]:
    print("cargo-ndk 4.1.2")
    sys.exit(0)
cwd = pathlib.Path.cwd()
expected = pathlib.Path(os.environ["EXPECTED_CRATE"])
assert cwd == expected, (str(cwd), str(expected))
assert (cwd / "Cargo.toml").is_file()
assert args[args.index("--manifest-path") + 1] == str(cwd / "Cargo.toml")
assert args[args.index("--platform") + 1] == "28"
assert args[-4:] == ["--", "build", "--locked", "--release"]
abi = args[args.index("--target") + 1]
targets = {"arm64-v8a": "aarch64-linux-android", "armeabi-v7a": "armv7-linux-androideabi",
           "x86_64": "x86_64-linux-android", "x86": "i686-linux-android"}
archive = cwd / "target" / targets[abi] / "release" / "libcreckless.a"
archive.parent.mkdir(parents=True, exist_ok=True)
archive.write_bytes(("fixture-only:" + abi).encode())
with open(os.environ["BUILD_CALLS"], "a") as handle:
    handle.write(json.dumps({"abi": abi, "flags": os.environ["CARGO_ENCODED_RUSTFLAGS"].split("\\x1f")}) + "\\n")
''')
            rustup.chmod(0o755)
            caller = root / "unrelated caller"
            caller.mkdir()
            calls = root / "calls.jsonl"
            environment = dict(os.environ, CARGO_HOME=str(cargo_home),
                               EXPECTED_CRATE=str(repo / "rust"), BUILD_CALLS=str(calls),
                               ANDROID_API="28", RUST_STABLE_TOOLCHAIN="1.96.1",
                               CARGO_NDK_VERSION="4.1.2")
            result = subprocess.run(["bash", str(script)], cwd=caller, env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            expected = {"arm64-v8a": "+neon", "armeabi-v7a": "+neon,+vfpv3",
                        "x86_64": "+avx2,+popcnt", "x86": "+sse4.2,+popcnt"}
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual([call["abi"] for call in recorded], list(expected))
            for call in recorded:
                abi = call["abi"]
                self.assertEqual(call["flags"][:2], ["-C", "target-feature=" + expected[abi]])
                self.assertIn("--remap-path-prefix=" + str(repo) + "=/src/SwiftReckless", call["flags"])
                self.assertEqual((repo / "android-libs" / abi / "libcreckless.a").read_bytes(),
                                 ("fixture-only:" + abi).encode())
            self.assertEqual(list(caller.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
