#!/usr/bin/env python3
"""Real-VM developer journey: follows the README quick start (`microvm help`) with the release CLI.

Uses an isolated home, an existing guest image (--images), and the fixture project in
testdata/journey-project. Runtime preparation is seeded from --cache; missing verified inputs are
downloaded. The `deps` sandbox needs internet access to registry.npmjs.org.

Checks, in quick-start order: doctor before and after preparation, an explicitly networked install,
finish publishing the npm cache, an offline sandbox with no network that installs from that cache,
tests, piped input, exit status, Ctrl-C, the command deadline, an interactive shell (editing,
resize, Ctrl-C of a child, host terminal restoration), ls/inspect/logs, diff, finish, applying the
patch to a matching copy, an unchanged source checkout, and cleanup with rm and rm --purge.
TTL warnings and expiry, creation cancellation, and NAT are covered by test-terminal-macos.py and
test-isolation-macos.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import shutil
import signal
import subprocess
import tempfile
import time

import sys

sys.dont_write_bytecode = True  # Importing the terminal checks must not leave scripts/__pycache__.
SCRIPTS = pathlib.Path(__file__).resolve().parent
REPO = SCRIPTS.parent
spec = importlib.util.spec_from_file_location("terminal_checks", SCRIPTS / "test-terminal-macos.py")
terminal_checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal_checks)
Session = terminal_checks.Session


def tree_digest(root):
    """Content, mode, and symlink digest of every file under root, including .git."""
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        digest.update(f"{relative}\0{info.st_mode}\0".encode())
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default="node:24", help="Node runtime selection to prepare and use")
    parser.add_argument("--binary", type=pathlib.Path, default=REPO / ".build/release/microvm")
    parser.add_argument("--images", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/images")
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/cache",
                        help="verified inputs copied into the isolated home before runtime preparation")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("requires a virtualization-capable Mac and an entitled binary")
    arch = "aarch64" if platform.machine() == "arm64" else "x86_64"
    image = args.images.resolve() / arch
    for name in ("kernel", "initrd"):
        if not (image / name).is_file():
            parser.error(f"missing {image / name}; build an image first")
    binary = str(args.binary.resolve())

    with tempfile.TemporaryDirectory(prefix="microvm-journey-", dir="/tmp") as scratch:
        scratch = pathlib.Path(scratch)
        home = scratch / "home"
        (home / "images").mkdir(parents=True)
        (home / "images" / arch).symlink_to(image, target_is_directory=True)
        if args.cache.is_dir():
            shutil.copytree(args.cache, home / "cache")
        prefix = [binary, "--home", str(home)]

        def cli(*arguments, check=True, timeout=60, cwd=scratch):
            started = time.monotonic()
            result = subprocess.run(prefix + list(arguments), capture_output=True, text=True, timeout=timeout,
                                    cwd=cwd, stdin=subprocess.DEVNULL)
            result.seconds = time.monotonic() - started
            if check and result.returncode:
                raise AssertionError(f"{arguments}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
            return result

        # The developer's project: committed history plus uncommitted work, which clone imports.
        project = scratch / "project"
        shutil.copytree(REPO / "testdata/journey-project", project)
        git = ["git", "-c", "user.name=Journey", "-c", "user.email=journey@example.invalid"]
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=project, check=True)
        subprocess.run(git + ["add", "-A"], cwd=project, check=True)
        subprocess.run(git + ["commit", "-q", "-m", "fixture"], cwd=project, check=True)
        with (project / "index.js").open("a") as source:
            source.write("// uncommitted on the host\n")
        (project / "NOTES.md").write_text("untracked notes\n")
        baseline = scratch / "baseline"
        shutil.copytree(project, baseline, symlinks=True)
        before = tree_digest(project)

        try:
            doctor = cli("doctor", "--runtime", args.runtime, "--json", check=False)
            report = json.loads(doctor.stdout)
            assert doctor.returncode == 1 and report["ok"] is False and doctor.stderr == "", doctor
            errors = {check["id"]: check for check in report["checks"] if check["status"] == "error"}
            assert set(errors) == {"runtime"}, errors
            assert "runtime prepare" in errors["runtime"]["recovery"], errors
            print("PASS: doctor exits 1 before preparation, with only the runtime check failing and "
                  "`runtime prepare` as the recovery", flush=True)

            prepared = cli("runtime", "prepare", ".", "--runtime", args.runtime, timeout=1200, cwd=REPO)
            assert "Preparing the runtime" in prepared.stderr, prepared.stderr
            assert json.loads(cli("doctor", "--runtime", args.runtime, "--json").stdout)["ok"] is True
            print(f"PASS: runtime prepare ({prepared.seconds:.0f}s) verifies the runtime; doctor then exits 0", flush=True)

            deps = cli("clone", "./project", "deps", "--runtime", args.runtime, "--network", "filtered", timeout=300)
            assert "Network: filtered" in deps.stdout and "Booting the sandbox" in deps.stderr, deps
            install = cli("exec", "deps", "--timeout", "300", "--", "npm", "ci", timeout=330)
            assert "added 1 package" in install.stdout, install.stdout
            cli("finish", "deps", timeout=300)
            caches = list((home / "dependency-cache").glob("*.tar"))
            assert len(caches) == 1, caches
            print(f"PASS: --network filtered sandbox installs with npm ci ({install.seconds:.0f}s); "
                  "finish saves the npm cache", flush=True)

            demo = cli("clone", "./project", "demo", "--runtime", args.runtime, timeout=300)
            assert "Network: none" in demo.stdout, demo.stdout
            interfaces = cli("exec", "demo", "--", "sh", "-c",
                             'for i in /sys/class/net/*; do [ -e "$i/device" ] && echo nic; done; true')
            assert "nic" not in interfaces.stdout, interfaces.stdout
            reach = cli("exec", "demo", "--", "node", "-e",
                        "require('https').get('https://registry.npmjs.org/', () => process.exit(0))"
                        ".on('error', e => { console.error(e.code); process.exit(3) })", check=False)
            assert reach.returncode == 3, reach
            offline = cli("exec", "demo", "--", "npm", "ci", "--offline", timeout=120)
            assert "added 1 package" in offline.stdout, offline.stdout
            tests = cli("exec", "demo", "--", "npm", "test", timeout=120)
            # Node 22 prints TAP summaries (# pass); Node 24's default reporter prints ℹ pass.
            assert any(f"{mark} pass 2" in tests.stdout and f"{mark} fail 0" in tests.stdout for mark in ("#", "ℹ")), tests.stdout
            print("PASS: default sandbox has no NIC and cannot reach the registry; npm ci --offline uses the "
                  "saved cache; npm test passes", flush=True)

            counted = subprocess.run(prefix + ["exec", "demo", "--", "wc", "-c"], input=b"abc\n" * 50000,
                                     capture_output=True, timeout=60, cwd=scratch)
            assert counted.returncode == 0 and counted.stdout.strip() == b"200000", counted
            failed = cli("exec", "demo", "--", "sh", "-c", "echo out; echo err >&2; exit 7", check=False)
            assert (failed.returncode, failed.stdout, failed.stderr) == (7, "out\n", "err\n"), failed
            deadline = cli("exec", "demo", "--timeout", "2", "--", "sleep", "30", check=False)
            assert deadline.returncode == 124 and "timed out after 2s" in deadline.stderr, deadline
            interrupted = subprocess.Popen(prefix + ["exec", "demo", "--", "sh", "-c", "echo ready; sleep 30"],
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert interrupted.stdout.readline() == b"ready\n"
            interrupted.send_signal(signal.SIGINT)
            assert interrupted.wait(timeout=10) == 130
            assert cli("exec", "demo", "--", "echo", "usable").stdout == "usable\n"
            print("PASS: 200 KB piped stdin, separate streams with exit 7, deadline exit 124, Ctrl-C exit 130; "
                  "sandbox stays usable", flush=True)

            shell = Session(prefix, ["shell", "demo"], rows=30, cols=100)
            shell.read_until("# ")
            assert shell.is_raw()
            shell.type("PS1='journey$ '\r")
            shell.read_until("journey$ ")

            def say(line, expect):
                shell.output = b""
                shell.type(line + "\r")
                shell.read_until(expect + "\r\njourney$ ")

            say('[ "$(pwd -P)" = "$(readlink -f /workspace)" ] && echo in-workspace', "in-workspace")
            say("echo '// edited in the shell' >> index.js && tail -n 1 index.js", "// edited in the shell")
            shell.resize(40, 120)
            time.sleep(0.5)
            say("stty size", "40 120")
            shell.output = b""
            shell.type("sleep 30\r")
            time.sleep(1.5)
            shell.type("\x03")
            shell.read_until("journey$ ", timeout=10)
            # A bare exit would return the interrupted sleep's status (130), as in any POSIX shell.
            shell.type("exit 0\r")
            assert shell.finish() == 0, shell.text
            assert "left the shell; demo is still running" in shell.text, shell.text
            print("PASS: shell opens in /workspace, edits a file, resizes, survives Ctrl-C of a child, "
                  "and restores the host terminal", flush=True)

            listed = {entry["name"]: entry for entry in json.loads(cli("ls", "--json").stdout)}
            assert listed["demo"]["phase"] == "running" and listed["demo"]["network"] == "none", listed
            assert listed["deps"]["phase"] == "completed" and listed["deps"]["resultDirectory"], listed
            assert "demo" in cli("ls").stdout
            inspected = json.loads(cli("inspect", "demo", "--json").stdout)
            assert inspected["sandboxExpiresAtUnix"] and inspected["resultExpiresAtUnix"], inspected
            assert inspected["sandboxExpiresAtUnix"] < inspected["resultExpiresAtUnix"], inspected
            rows = [line.split() for line in cli("logs", "demo", "--list").stdout.splitlines()[1:]]
            formats = [row[7] for row in rows]
            assert formats.count("terminal") == 1 and "separate" in formats, rows
            # The COMMAND column is the program name; the second npm run is `npm test`, after `npm ci --offline`.
            test_run = [row[0] for row in rows if row[8] == "npm"][1]
            assert rows[int(test_run)][8:] == ["npm"] and [row[8] for row in rows].count("/bin/sh") == 1, rows
            replay = cli("logs", "demo", "--exec", test_run)
            assert replay.stdout == tests.stdout, (replay.stdout, tests.stdout)
            print("PASS: ls, inspect, and logs report the sandbox, independent deadlines, and replay "
                  "the npm test output exactly", flush=True)

            patch = cli("diff", "demo").stdout
            assert "+// edited in the shell" in patch and "node_modules" not in patch, patch
            assert "+// uncommitted on the host" not in patch, "imported uncommitted work is the baseline"
            finished = json.loads(cli("finish", "demo", "--json", timeout=300).stdout)
            # The journey ran failing commands on purpose (exit 7, the deadline, Ctrl-C), so the phase is failed;
            # finish still exports.
            assert finished["sandbox"] == "stopped" and finished["phase"] == "failed", finished
            assert finished["priorCommandFailure"] is True, finished
            assert finished["hostCheckout"] == "unchanged", finished
            assert pathlib.Path(finished["patch"]).read_text() == patch
            applied = subprocess.run(["sh", "-c", finished["applyCommand"]], cwd=baseline, capture_output=True, text=True)
            assert applied.returncode == 0, applied
            assert (baseline / "index.js").read_text().endswith("// uncommitted on the host\n// edited in the shell\n")
            assert tree_digest(project) == before, "the source checkout changed"
            print("PASS: diff and finish export the shell edit; the printed git apply command applies to a matching "
                  "copy; the source checkout is unchanged", flush=True)

            assert cli("rm", "demo").stdout == "removed demo\n"
            cli("rm", "deps")
            assert pathlib.Path(finished["resultDirectory"]).is_dir(), "rm keeps the published result"
            for entry in json.loads(cli("ls", "--json").stdout):
                cli("rm", entry["id"], "--purge")
            assert not pathlib.Path(finished["resultDirectory"]).exists()
            assert json.loads(cli("ls", "--json").stdout) == []
            vms = list((home / "vms").iterdir()) if (home / "vms").exists() else []
            assert vms == [], vms
            print("PASS: rm releases names and keeps results; rm --purge deletes them; nothing is left running",
                  flush=True)
        except BaseException:
            log = home / "daemon.log"
            if log.exists():
                print(log.read_text()[-20000:])
            raise
        finally:
            subprocess.run(["pkill", "-f", f"{binary} --home {home} daemon"], check=False)


if __name__ == "__main__":
    main()
