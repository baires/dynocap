#!/usr/bin/env python3
"""Real-VM terminal check: drives `exec --tty` from a host PTY. Uses an isolated home and an existing guest image.

The CLI runs with the PTY as its controlling terminal, so window changes produce a real SIGWINCH.
Checks input, initial size, resizing, Ctrl-C, exit status, host terminal restoration (including after
SIGKILL, guest connection loss, and daemon death), and that the sandbox stays usable. Also interrupts
an ordinary (non-terminal) foreground command. Unless --skip-project is given, it prepares a node:22
runtime (seeded from --cache; missing verified inputs are downloaded) and checks terminal transcripts
in a project task's logs, before and after finish.
"""
import argparse
import fcntl
import os
import pathlib
import platform
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time


def winsize(rows, cols):
    return struct.pack("HHHH", rows, cols, 0, 0)


def settings(fd):
    # Read through the ptmx side: macOS revokes the session's pts descriptors once the
    # controlling process exits. PENDIN is transient: BSD sets it when canonical mode returns.
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~termios.PENDIN
    return attrs


class Session:
    """One CLI process whose stdin, stdout, stderr, and controlling terminal are a host PTY."""

    def __init__(self, prefix, arguments, rows=24, cols=80):
        self.ptmx, self.pts = os.openpty()
        fcntl.ioctl(self.ptmx, termios.TIOCSWINSZ, winsize(rows, cols))
        self.before = settings(self.ptmx)
        self.output = b""

        def controlling_terminal():
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(
            prefix + arguments, stdin=self.pts, stdout=self.pts, stderr=self.pts,
            start_new_session=True, preexec_fn=controlling_terminal)

    @property
    def text(self):
        return self.output.decode(errors="replace")

    def read_until(self, needle, timeout=20):
        deadline = time.monotonic() + timeout
        while needle.encode() not in self.output:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for {needle!r}; output {self.text!r}")
            ready, _, _ = select.select([self.ptmx], [], [], min(remaining, 0.2))
            if ready:
                try:
                    chunk = os.read(self.ptmx, 4096)
                except OSError:
                    chunk = b""
                if not chunk and self.process.poll() is not None:
                    raise AssertionError(f"CLI exited {self.process.returncode} before {needle!r}; output {self.text!r}")
                self.output += chunk

    def type(self, text):
        os.write(self.ptmx, text.encode())

    def resize(self, rows, cols):
        # The kernel delivers SIGWINCH to the PTY's foreground process group: the CLI.
        fcntl.ioctl(self.ptmx, termios.TIOCSWINSZ, winsize(rows, cols))

    def is_raw(self):
        lflag = termios.tcgetattr(self.ptmx)[3]
        return not lflag & (termios.ICANON | termios.ECHO | termios.ISIG)

    def finish(self, timeout=20, settle=3):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None:
            if time.monotonic() >= deadline:
                self.process.kill()
                raise AssertionError(f"CLI did not exit; output {self.text!r}")
            ready, _, _ = select.select([self.ptmx], [], [], 0.1)
            if ready:
                try:
                    self.output += os.read(self.ptmx, 4096)
                except OSError:
                    pass
        # SIGKILL leaves restoration to the CLI's guardian process, which needs a moment.
        settled = time.monotonic() + settle
        while settings(self.ptmx) != self.before and time.monotonic() < settled:
            time.sleep(0.05)
        restored = settings(self.ptmx) == self.before
        os.close(self.ptmx)
        os.close(self.pts)
        assert restored, f"host terminal was not restored; output {self.text!r}"
        return self.process.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    repo = pathlib.Path(__file__).resolve().parent.parent
    parser.add_argument("--binary", type=pathlib.Path, default=repo / ".build/release/microvm")
    parser.add_argument("--images", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/images")
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/cache",
                        help="verified inputs copied into the isolated home before runtime preparation")
    parser.add_argument("--skip-project", action="store_true", help="skip the project task and runtime preparation")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("requires a virtualization-capable Mac and an entitled binary")
    arch = "aarch64" if platform.machine() == "arm64" else "x86_64"
    image = args.images.resolve() / arch
    for name in ("kernel", "initrd"):
        if not (image / name).is_file():
            parser.error(f"missing {image / name}; build an image first")
    binary = str(args.binary.resolve())
    with tempfile.TemporaryDirectory(prefix="microvm-terminal-", dir="/tmp") as scratch:
        home = pathlib.Path(scratch)
        (home / "images").mkdir()
        (home / "images" / arch).symlink_to(image, target_is_directory=True)
        prefix = [binary, "--home", str(home)]

        def cli(*arguments, check=True, timeout=25):
            result = subprocess.run(prefix + list(arguments), capture_output=True, text=True, timeout=timeout,
                                    stdin=subprocess.DEVNULL)
            if check and result.returncode:
                raise AssertionError(f"{arguments}: {result.returncode} {result.stderr}")
            return result

        with (home / "terminal-daemon.log").open("w+") as log:
            daemon = subprocess.Popen(prefix + ["daemon"], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while not (home / "daemon.sock").exists():
                    if daemon.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError("daemon failed to start")
                    time.sleep(0.02)
                cli("run", "--name", "term")

                probe = Session(prefix, ["exec", "-t", "term", "--", "sh", "-c",
                                         'tty; stty size; echo "TERM=$TERM"; echo err >&2'], rows=33, cols=101)
                probe.read_until("TERM=xterm-256color")
                assert probe.finish() == 0, probe.text
                assert "/dev/pts/" in probe.text and "33 101" in probe.text, probe.text
                # stderr shares the terminal: it arrives in the same stream, after stdout.
                assert "xterm-256color\r\nerr\r\n" in probe.text, probe.text
                print("PASS: controlling guest terminal with the host size; combined output; terminal restored", flush=True)

                shell = Session(prefix, ["exec", "-it", "--env", "PS1=mvm$ ", "--timeout", "120", "term", "--", "sh", "-i"])
                shell.read_until("mvm$ ")
                assert shell.is_raw(), "host terminal is not raw during the session"

                def run(line, expect):
                    # Wait for the prompt after the result, so the next match cannot see a stale prompt.
                    shell.output = b""
                    shell.type(line + "\r")
                    shell.read_until(expect)
                    shell.read_until(expect + "\r\nmvm$ ")

                run("echo $((6*7))", "42")
                shell.resize(40, 120)
                time.sleep(0.5)
                run("stty size", "40 120")
                shell.output = b""
                shell.type("sleep 30\r")
                time.sleep(1.5)
                started = time.monotonic()
                shell.type("\x03")
                shell.read_until("mvm$ ", timeout=10)
                assert time.monotonic() - started < 5, "Ctrl-C did not end the foreground job promptly"
                shell.type("exit 3\r")
                assert shell.finish() == 3, shell.text
                print("PASS: interactive shell input, resize via SIGWINCH, Ctrl-C ends only the foreground job, exit 3", flush=True)

                sleeper = Session(prefix, ["exec", "-t", "term", "--", "sh", "-c", "echo ready; exec sleep 30"])
                sleeper.read_until("ready")
                started = time.monotonic()
                sleeper.type("\x03")
                assert sleeper.finish(timeout=10) == 130, sleeper.text
                assert time.monotonic() - started < 5
                print("PASS: Ctrl-C ends a foreground terminal command with status 130; terminal restored", flush=True)

                terminated = Session(prefix, ["exec", "-t", "term", "--", "sh", "-c", "echo ready; exec sleep 30"])
                terminated.read_until("ready")
                terminated.process.send_signal(signal.SIGTERM)
                assert terminated.finish(timeout=10) == 143, terminated.text
                assert cli("exec", "term", "--", "echo", "usable").stdout == "usable\n"
                print("PASS: host SIGTERM restores the terminal and exits 143; sandbox remains usable", flush=True)

                # Ticket 12: an ordinary foreground command, interrupted from the host.
                plain = subprocess.Popen(prefix + ["exec", "term", "--", "sh", "-c", "echo ready; sleep 30"],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                assert plain.stdout.readline() == b"ready\n"
                started = time.monotonic()
                plain.send_signal(signal.SIGINT)
                assert plain.wait(timeout=10) == 130, plain.stderr.read()
                assert time.monotonic() - started < 5
                assert cli("exec", "term", "--", "echo", "usable").stdout == "usable\n"
                print("PASS: Ctrl-C of a non-terminal foreground command exits 130; sandbox remains usable", flush=True)

                cli("run", "--name", "brief", "--ttl", "8")
                expiring = Session(prefix, ["exec", "-t", "brief", "--timeout", "60", "--", "sh", "-c", "echo ready; sleep 60"])
                expiring.read_until("ready")
                assert expiring.finish(timeout=30) == 1, expiring.text
                assert "lifetime expired" in expiring.text, expiring.text
                print("PASS: sandbox expiry ends the terminal session and restores the terminal", flush=True)

                killed = Session(prefix, ["exec", "-t", "term", "--", "sh", "-c", "echo ready; sleep 60"])
                killed.read_until("ready")
                assert killed.is_raw()
                killed.process.kill()
                assert killed.finish(timeout=10) == -signal.SIGKILL, killed.text
                assert cli("exec", "term", "--", "echo", "usable").stdout == "usable\n"
                print("PASS: SIGKILL of the CLI still restores the terminal; sandbox remains usable", flush=True)

                cli("run", "--name", "lost")
                lost = Session(prefix, ["exec", "-t", "lost", "--timeout", "60", "--", "sh", "-c", "echo ready; sleep 60"])
                lost.read_until("ready")
                # This exec is served by the agent it kills, so it fails too.
                cli("exec", "lost", "--", "sh", "-c", "kill -9 $(pidof microvm-agent)", check=False)
                assert lost.finish(timeout=30) == 1, lost.text
                assert cli("exec", "term", "--", "echo", "usable").stdout == "usable\n", "another sandbox was affected"
                print("PASS: guest agent loss ends the session with status 1 and restores the terminal", flush=True)

                if not args.skip_project:
                    if args.cache.is_dir():
                        shutil.copytree(args.cache, home / "cache", dirs_exist_ok=True)
                    (home / "cache").mkdir(exist_ok=True)
                    seeded = set(os.listdir(home / "cache"))
                    cli("runtime", "prepare", str(repo), "--runtime", "node:22", timeout=900)
                    fetched = sorted(set(os.listdir(home / "cache")) - seeded)
                    print(f"PASS: runtime prepared ({len(fetched)} inputs downloaded beyond the seed)", flush=True)
                    project = home / "project"
                    project.mkdir()
                    (project / "hello.txt").write_text("alpha\n")
                    cli("clone", str(project), "proj", "--memory", "512", "--ttl", "600", timeout=180)
                    transcript = Session(prefix, ["exec", "-t", "proj", "--", "sh", "-c", 'printf "a\\tb\\n"; echo err >&2; exit 4'])
                    transcript.read_until("err")
                    assert transcript.finish() == 4, transcript.text
                    # /workspace is a symlink to /work/project; compare physical paths.
                    task = Session(prefix, ["task", "exec", "-t", "proj", "--", "sh", "-c",
                                            '[ "$(pwd -P)" = "$(readlink -f /workspace)" ] && echo in-workspace; tty'])
                    task.read_until("/dev/pts/")
                    assert task.finish() == 0 and "in-workspace\r\n" in task.text, repr(task.text)
                    rows = [line.split() for line in cli("logs", "proj", "--list").stdout.splitlines()[1:]]
                    terminal_ids = [row[0] for row in rows if "terminal" in row]
                    assert len(terminal_ids) == 2, rows
                    expected = b"a\tb\r\nerr\r\n"

                    def replay():
                        result = subprocess.run(prefix + ["logs", "proj", "--exec", terminal_ids[0]],
                                                capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                        assert result.returncode == 0, result.stderr
                        assert result.stdout == expected and result.stderr == b"", (result.stdout, result.stderr)

                    replay()
                    print("PASS: project task journals one terminal transcript and replays it to stdout only", flush=True)
                    cli("finish", "proj", timeout=300)
                    replay()
                    published = list(home.glob(f"tasks/*/result/{terminal_ids[0]}.terminal"))
                    assert len(published) == 1 and published[0].read_bytes() == expected, published
                    assert not (published[0].parent / f"{terminal_ids[0]}.stderr").exists()
                    print("PASS: finish publishes N.terminal without a stderr file; logs replay it after shutdown", flush=True)

                # Last: the daemon dies under a live session, taking its sandboxes with it.
                orphan = Session(prefix, ["exec", "-t", "term", "--", "sh", "-c", "echo ready; sleep 60"])
                orphan.read_until("ready")
                daemon.kill()
                daemon.wait(timeout=15)
                assert orphan.finish(timeout=15) == 1, orphan.text
                print("PASS: daemon death ends the session with status 1 and restores the terminal", flush=True)
            except BaseException:
                log.flush()
                print((home / "terminal-daemon.log").read_text())
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
