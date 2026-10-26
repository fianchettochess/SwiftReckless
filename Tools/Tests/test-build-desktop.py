#!/usr/bin/env python3
"""Desktop invocation contracts; synthetic archives are not real-engine proof."""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest


class DesktopBuilderLinkerTests(unittest.TestCase):
    def run_builder(self, host, prefer_msvc):
        with tempfile.TemporaryDirectory(prefix="reckless desktop linker ") as temporary:
            root = Path(temporary).resolve()
            repo = root / "repository with spaces"
            (repo / "Tools").mkdir(parents=True)
            (repo / "rust").mkdir()
            (repo / "rust/Cargo.toml").write_text("[package]\nname='fixture'\n")
            script = repo / "Tools/build-desktop.sh"
            shutil.copyfile(Path(__file__).resolve().parents[1] / script.name, script)
            cargo_home = root / "cargo home"
            (cargo_home / "bin").mkdir(parents=True)
            shadow = root / "git usr bin"
            msvc = root / "Visual Studio bin"
            shadow.mkdir(); msvc.mkdir()
            def executable(path, text):
                path.write_text(text)
                path.chmod(0o755)
            executable(shadow / "uname", "#!/bin/sh\nprintf '%s\\n' '" + host + "'\n")
            executable(shadow / "link.exe", "#!/bin/sh\nexit 42\n")
            executable(msvc / "cl.exe", "#!/bin/sh\nexit 0\n")
            executable(msvc / "link.exe", "#!/bin/sh\nexit 0\n")
            executable(cargo_home / "bin/rustup", r"""#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
if args[:1] in (["toolchain"], ["target"]):
    sys.exit(0)
assert args[:4] == ["run", "1.96.1", "cargo", "build"], args
assert "--locked" in args and "--release" in args
manifest = pathlib.Path(args[args.index("--manifest-path") + 1])
assert manifest == pathlib.Path(os.environ["EXPECTED_CRATE"]) / "Cargo.toml"
triple = args[args.index("--target") + 1]
linker = shutil.which("link.exe")
assert linker == os.environ["EXPECTED_LINKER"], (linker, os.environ["EXPECTED_LINKER"])
with open(os.environ["LINK_CALLS"], "a") as output:
    output.write(json.dumps({"triple": triple, "linker": linker}) + "\n")
directory = manifest.parent / "target" / triple / "release"
directory.mkdir(parents=True, exist_ok=True)
(directory / "creckless.lib").write_bytes(b"invocation-fixture-only")
""")
            calls = root / "calls.jsonl"
            environment = dict(os.environ, CARGO_HOME=str(cargo_home),
                RUST_STABLE_TOOLCHAIN="1.96.1", EXPECTED_CRATE=str(repo / "rust"),
                EXPECTED_LINKER=str((msvc if prefer_msvc else shadow) / "link.exe"),
                LINK_CALLS=str(calls), PATH=str(shadow) + os.pathsep + str(msvc) + os.pathsep + os.environ["PATH"])
            caller = root / "unrelated caller"
            caller.mkdir()
            result = subprocess.run(["bash", str(script), "windows", "windows-arm64"],
                cwd=caller, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual([row["triple"] for row in recorded],
                ["x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"])
            self.assertTrue(all(row["linker"] == environment["EXPECTED_LINKER"] for row in recorded))
            commands = [shlex.split(line.strip()) for line in result.stdout.splitlines()
                        if "swift build -Xlinker" in line]
            self.assertEqual(len(commands), 2)
            for command, row in zip(commands, recorded):
                directory = repo / "rust/target" / row["triple"] / "release"
                self.assertEqual(command, ["MSYS2_ARG_CONV_EXCL=/LIBPATH:", "swift", "build",
                    "-Xlinker", "/LIBPATH:" + str(directory), "-Xlinker", str(directory / "creckless.lib")])
            self.assertEqual(list(caller.iterdir()), [])

    def test_windows_bash_prefers_msvc_over_git_link(self):
        for host in ["MINGW64_NT-10.0", "MSYS_NT-10.0", "CYGWIN_NT-10.0"]:
            with self.subTest(host=host):
                self.run_builder(host, prefer_msvc=True)

    def test_other_hosts_preserve_the_original_search_path(self):
        for host in ["Linux", "Darwin"]:
            with self.subTest(host=host):
                self.run_builder(host, prefer_msvc=False)


if __name__ == "__main__":
    unittest.main()
