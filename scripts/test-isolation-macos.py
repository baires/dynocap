#!/usr/bin/env python3
"""Real-VM isolation smoke test. Uses an isolated home and an existing guest image."""
import argparse
import json
import pathlib
import platform
import socket
import struct
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    repo = pathlib.Path(__file__).resolve().parent.parent
    parser.add_argument("--binary", type=pathlib.Path, default=repo / ".build/release/dynocap")
    parser.add_argument("--images", type=pathlib.Path, default=pathlib.Path.home() / ".dynocap/images")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("requires a virtualization-capable Mac and an entitled binary")
    arch = "aarch64" if platform.machine() == "arm64" else "x86_64"
    image = args.images.resolve() / arch
    for name in ("kernel", "initrd"):
        if not (image / name).is_file():
            parser.error(f"missing {image / name}; build an image first")
    binary = str(args.binary.resolve())
    with tempfile.TemporaryDirectory(prefix="dynocap-isolation-", dir="/tmp") as scratch:
        home = pathlib.Path(scratch)
        (home / "images").mkdir()
        (home / "images" / arch).symlink_to(image, target_is_directory=True)
        prefix = [binary, "--home", str(home)]

        def cli(*arguments, check=True, timeout=25):
            result = subprocess.run(prefix + list(arguments), capture_output=True, text=True, timeout=timeout)
            if check and result.returncode:
                raise AssertionError(f"{arguments}: {result.stderr}")
            return result

        with (home / "smoke-daemon.log").open("w+") as log:
            daemon = subprocess.Popen(prefix + ["daemon"], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while not (home / "daemon.sock").exists():
                    if daemon.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError("daemon failed to start")
                    time.sleep(0.02)

                cli("run", "--name", "offline")
                interfaces = cli("exec", "offline", "--", "ls", "/sys/class/net").stdout.split()
                assert "lo" in interfaces, interfaces
                # Kernels may also expose inert tunnel devices such as sit0; no NIC may exist.
                cli("exec", "offline", "--", "sh", "-c",
                    'for interface in /sys/class/net/*; do [ ! -e "$interface/device" ] || exit 1; done')
                assert not cli("exec", "offline", "--", "ip", "route").stdout.strip()
                record = json.loads((home / "vms/offline/state.json").read_text())
                assert record["network"] == "none" and record["ttlSeconds"] == 1800, record
                # A connection to a public IP must fail when no virtual NIC is attached.
                blocked = cli("exec", "offline", "--", "sh", "-c",
                              "printf 'GET / HTTP/1.0\r\n\r\n' | nc -w 2 1.1.1.1 80", check=False)
                assert blocked.returncode != 0, blocked.stdout
                print("PASS: default offline guest has no NIC or routes, vsock exec works, outbound TCP fails", flush=True)

                cli("run", "--name", "online", "--network", "nat")
                # Agent readiness does not imply DHCP readiness: wait independently for a route.
                cli("exec", "online", "--timeout", "20", "--", "sh", "-c",
                    "i=0; until ip route | grep -q '^default'; do "
                    "i=$((i+1)); [ $i -lt 15 ] || exit 1; sleep 1; done")
                cli("exec", "online", "--timeout", "15", "--", "sh", "-c",
                    "printf 'GET / HTTP/1.0\r\nHost: 1.1.1.1\r\n\r\n' | "
                    "nc -w 5 1.1.1.1 80 > /tmp/response; grep -q '^HTTP/' /tmp/response")
                record = json.loads((home / "vms/online/state.json").read_text())
                assert record["network"] == "nat", record
                print("PASS: explicit NAT obtains DHCP and reaches public HTTP", flush=True)

                sdk = (repo / "sdk/typescript/dist/index.js").as_uri()
                mcp = (repo / "sdk/mcp/dist/tools.js").as_uri()
                client_test = """
                  import assert from 'node:assert/strict';
                  const { Sandbox } = await import(process.argv[1]);
                  const { dynocapRun, dynocapExec, dynocapDestroy } = await import(process.argv[2]);
                  const home = { home: process.argv[3] };
                  const sdk = await Sandbox.create({ ...home, name: 'sdk' });
                  assert.equal((await sdk.exec('echo sdk')).stdout.trim(), 'sdk');
                  const tty = await sdk.exec('tty; stty size; echo err >&2', { terminal: { rows: 30, cols: 100 } });
                  assert.equal(tty.exitCode, 0);
                  assert.match(tty.stdout, /^\\/dev\\/pts\\/\\d+\\r\\n30 100\\r\\nerr\\r\\n$/);
                  assert.equal(tty.stderr, '');
                  assert.equal((await Sandbox.list(home)).find(s => s.name === 'sdk').network, 'none');
                  await sdk.destroy();
                  assert.equal((await dynocapRun({name: 'mcp'}, home)).isError, undefined);
                  assert.equal((await dynocapExec({name: 'mcp', command: 'true'}, home)).isError, undefined);
                  const term = await dynocapExec({name: 'mcp', command: 'stty size', terminal: true}, home);
                  assert.equal(term.content[0].text, 'exit 0\\nterminal:\\n24 80\\r\\n');
                  assert.equal((await dynocapRun({name: 'denied', network: 'nat'}, home)).isError, true);
                  assert.equal((await dynocapExec({name: 'online', command: 'true'}, home)).isError, true);
                  assert.equal((await dynocapExec({name: 'online', command: 'true'}, {...home, allowNat: true})).isError, undefined);
                  await dynocapDestroy('mcp', home);
                """
                subprocess.run(["node", "--input-type=module", "-e", client_test, sdk, mcp, str(home)], check=True, timeout=30)
                print("PASS: real SDK/MCP offline exec, terminal exec, and MCP NAT permission checks", flush=True)

                cli("run", "--name", "short", "--ttl", "2")
                started = time.monotonic()
                expired = cli("exec", "short", "--timeout", "30", "--", "sleep", "30", check=False, timeout=15)
                assert expired.returncode != 0 and "lifetime expired" in expired.stderr, expired
                assert time.monotonic() - started < 10
                deadline = time.monotonic() + 5
                while (home / "vms/short").exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert not (home / "vms/short").exists(), "expired sandbox record not removed"
                print("PASS: short TTL terminates active exec and removes sandbox after teardown", flush=True)

                # A client that stops reading a noisy command must not block host teardown.
                cli("run", "--name", "noisy", "--ttl", "2")
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as unread:
                    unread.connect(str(home / "daemon.sock"))
                    payload = json.dumps({"name": "noisy", "argv": ["yes"], "env": [], "cwd": "", "timeoutSeconds": 30}).encode()
                    unread.sendall(struct.pack(">IB", len(payload) + 1, 2) + payload)
                    deadline = time.monotonic() + 8
                    while (home / "vms/noisy").exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    assert not (home / "vms/noisy").exists(), "unread output prevented TTL teardown: " + (home / "vms/noisy/state.json").read_text()
                print("PASS: unread noisy output cannot prevent TTL teardown", flush=True)

                cli("runtime", "prepare", str(repo), "--runtime", "node:24", timeout=180)
                print("PASS: runtime prepared for interruption check", flush=True)
                kept = home / "tasks" / "task-kept" / "result"
                kept.mkdir(parents=True)
                (kept / "changes.patch").write_text("kept")
                now = int(time.time())
                (home / "tasks" / "task-kept" / "task.json").write_text(json.dumps({
                    "id": "task-kept", "name": "kept", "phase": "completed", "runtimeDigest": "digest",
                    "createdAtUnix": now, "expiresAtUnix": now + 86400, "resultDirectory": str(kept),
                    "network": "none", "commands": [], "logBytes": 0, "timingsMS": {},
                }))
                project = home / "project"
                project.mkdir()
                (project / "hello.txt").write_text("alpha\n")
                # hello.txt does not name a language, so clone would ask for shell:1. This check
                # interrupts creation of the runtime prepared above.
                clone = subprocess.Popen(
                    prefix + ["clone", str(project), "cancelled", "--runtime", "node:24", "--memory", "256", "--cpus", "1", "--ttl", "120"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                saw_task = False
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and clone.poll() is None:
                    if (home / "tasks").exists() and any(path.name != "task-kept" for path in (home / "tasks").iterdir()):
                        saw_task = True
                        break
                    time.sleep(0.05)
                if not saw_task:
                    out, err = clone.communicate(timeout=20)
                    raise AssertionError(f"clone ended before a sandbox existed: {clone.returncode}\n{err}\n{out}")
                try:
                    clone.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    pass
                out, err = clone.communicate(timeout=90)
                deadline = time.monotonic() + 30
                settled = None
                while time.monotonic() < deadline:
                    leftovers = [path for path in (home / "tasks").iterdir() if path.name != "task-kept"]
                    if not leftovers:
                        settled = []
                        break
                    readable = []
                    for path in leftovers:
                        task_file = path / "task.json"
                        if not task_file.is_file():
                            continue
                        try:
                            record = json.loads(task_file.read_text())
                        except (OSError, json.JSONDecodeError):
                            continue
                        if record.get("phase") == "interrupted":
                            readable.append(record)
                    if len(readable) == len(leftovers):
                        settled = readable
                        break
                    time.sleep(0.05)
                if settled is None:
                    raise AssertionError(f"interrupted creation did not settle\n{err}\n{out}")
                assert (kept / "changes.patch").read_text() == "kept"
                assert (home / "vms" / "offline").exists() and (home / "vms" / "online").exists()
                if settled:
                    reported = (settled[0].get("message") or "") + err + out
                    assert "dynocap rm cancelled --force" in reported, reported
                    assert settled[0]["name"] == "cancelled"
                    cli("rm", "cancelled", "--force")
                    assert not any(path.name != "task-kept" for path in (home / "tasks").iterdir())
                vm_names = {path.name for path in (home / "vms").iterdir()} if (home / "vms").exists() else set()
                assert vm_names <= {"offline", "online"}, vm_names
                assert (kept / "changes.patch").read_text() == "kept"
                print("PASS: interrupted creation cleans up or reports dynocap rm cancelled --force", flush=True)

                listed = json.loads(cli("ps", "--json").stdout)
                assert [(entry["name"], entry["kind"]) for entry in listed] == [
                    ("offline", "sandbox"), ("online", "sandbox")], listed
                refused = cli("destroy", "offline", check=False)
                assert refused.returncode == 1 and "--force" in refused.stderr, refused
                assert cli("exec", "offline", "--", "echo", "kept").stdout == "kept\n"
                destroyed = json.loads(cli("destroy", "offline", "--force", "--json").stdout)
                assert destroyed == {"target": "offline", "removed": True, "purged": False}, destroyed
                cli("destroy", "online", "--force")
                assert json.loads(cli("ps", "--json").stdout) == []
                print("PASS: ps lists raw sandboxes; destroy refuses a live sandbox without --force", flush=True)
            except BaseException:
                log.flush()
                print((home / "smoke-daemon.log").read_text())
                raise
            finally:
                daemon.terminate()
                try:
                    daemon.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()


if __name__ == "__main__":
    main()
