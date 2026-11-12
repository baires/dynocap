#!/usr/bin/env python3
"""Real-VM runtime loop: prepare one runtime, warm its dependency seed under filtered egress, then
install and test offline. Uses an isolated home, an existing guest image (--images), and the runtime's
fixture under testdata/. Each runtime must reach only its own registry under filtered egress; a
repository URL clone checks that the task Git host is allowed alongside it.

    python3 scripts/validate-runtime-task.py --runtime node:24
    python3 scripts/validate-runtime-task.py --all
"""
import argparse
import json
import pathlib
import platform
import shutil
import subprocess
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
REPOSITORY_URL = "https://github.com/octocat/Hello-World.git"

NODE = dict(fixture="journey-project", install="npm ci", offline="npm ci --offline", test="npm test",
            registries=["registry.npmjs.org"])
RUNTIMES = {
    "node:24": NODE,
    "node:22": NODE,
    "go:1.27": dict(fixture="journey-go", install="go mod download", offline="go mod download", test="go test ./...",
                    registries=["proxy.golang.org", "sum.golang.org"]),
    "python:3.14": dict(fixture="journey-python", install="uv sync --frozen", offline="uv sync --offline --frozen",
                        test="uv run --offline --frozen python -m unittest -v",
                        registries=["pypi.org", "files.pythonhosted.org"]),
    "shell:1": dict(fixture="journey-shell", install=None, offline=None, test="bash test.sh", registries=[]),
}
UNLISTED = ["example.com"]


def validate(args, runtime, spec, arch):
    others = sorted({host for other in RUNTIMES.values() for host in other["registries"]} - set(spec["registries"]))
    with tempfile.TemporaryDirectory(prefix="microvm-runtime-", dir="/tmp") as scratch:
        scratch = pathlib.Path(scratch)
        home = scratch / "home"
        (home / "images").mkdir(parents=True)
        (home / "images" / arch).symlink_to(args.images.resolve() / arch, target_is_directory=True)
        if args.cache.is_dir():
            shutil.copytree(args.cache, home / "cache")
        binary = str(args.binary.resolve())
        prefix = [binary, "--home", str(home)]

        def cli(*arguments, check=True, timeout=300, cwd=scratch):
            result = subprocess.run(prefix + list(arguments), capture_output=True, text=True, timeout=timeout,
                                    cwd=cwd, stdin=subprocess.DEVNULL)
            if check and result.returncode:
                raise AssertionError(f"{arguments}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
            return result

        def sh(name, command, check=True, timeout=300, env=()):
            flags = [flag for pair in env for flag in ("--env", pair)]
            return cli("exec", name, "--timeout", str(timeout), *flags, "--", "sh", "-c", command, check=check,
                       timeout=timeout + 30)

        def resolves(name, host):
            # The name travels in the environment: an argv naming a registry would correctly stop seed publication.
            return sh(name, 'getent hosts "$PROBE" >/dev/null', check=False, timeout=30,
                      env=[f"PROBE={host}"]).returncode == 0

        project = scratch / "project"
        shutil.copytree(REPO / "testdata" / spec["fixture"], project)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=project, check=True)
        subprocess.run(["git", "-c", "user.name=Runtime", "-c", "user.email=runtime@example.invalid", "commit", "-q",
                        "--allow-empty", "-m", "fixture"], cwd=project, check=True)
        try:
            started = time.monotonic()
            cli("runtime", "prepare", ".", "--runtime", runtime, timeout=1800, cwd=REPO)
            assert json.loads(cli("doctor", "--runtime", runtime, "--json").stdout)["ok"] is True
            print(f"PASS {runtime}: prepared and verified ({time.monotonic() - started:.0f}s)", flush=True)

            cli("clone", str(project), "warm", "--runtime", runtime, "--network", "filtered")
            for host in spec["registries"]:
                assert resolves("warm", host), f"filtered egress denied {host}"
            for host in others + UNLISTED:
                assert not resolves("warm", host), f"filtered egress allowed {host}"
            if spec["install"]:
                sh("warm", spec["install"], timeout=600)
            sh("warm", spec["test"])
            cli("finish", "warm")
            seeds = list((home / "dependency-cache").glob("*.tar"))
            assert len(seeds) == (1 if spec["install"] else 0), seeds
            reach = ", ".join(spec["registries"]) or "no registry"
            print(f"PASS {runtime}: filtered egress reaches {reach} and nothing else; tests pass; "
                  f"finish publishes {len(seeds)} dependency seed(s)", flush=True)

            cli("clone", str(project), "offline", "--runtime", runtime)
            assert not resolves("offline", (spec["registries"] or UNLISTED)[0]), "offline sandbox resolved a name"
            if spec["offline"]:
                sh("offline", spec["offline"], timeout=600)
            sh("offline", spec["test"])
            cli("finish", "offline")
            via = "installs from the seed and " if spec["offline"] else ""
            print(f"PASS {runtime}: a sandbox with no network {via}passes tests", flush=True)

            cli("clone", REPOSITORY_URL, "repo", "--runtime", runtime, "--network", "filtered")
            assert "Hello" in sh("repo", "cat README").stdout
            assert resolves("repo", "github.com"), "filtered egress denied the repository host"
            assert not resolves("repo", "example.com")
            cli("finish", "repo")
            print(f"PASS {runtime}: a repository URL clones under filtered egress", flush=True)

            for entry in json.loads(cli("ls", "--json").stdout):
                cli("rm", entry["id"], "--purge")
        except BaseException:
            log = home / "daemon.log"
            if log.exists():
                print(log.read_text()[-20000:])
            raise
        finally:
            subprocess.run(["pkill", "-f", f"{binary} --home {home} daemon"], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", choices=sorted(RUNTIMES), action="append", default=[])
    parser.add_argument("--all", action="store_true", help="validate every runtime in turn")
    parser.add_argument("--binary", type=pathlib.Path, default=REPO / ".build/release/microvm")
    parser.add_argument("--images", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/images")
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path.home() / ".microvm/cache",
                        help="verified inputs copied into the isolated home before runtime preparation")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("requires a virtualization-capable Mac and an entitled binary")
    runtimes = sorted(RUNTIMES) if args.all else args.runtime
    if not runtimes:
        parser.error("pass --runtime NAME:VERSION or --all")
    arch = "aarch64" if platform.machine() == "arm64" else "x86_64"
    for runtime in runtimes:
        validate(args, runtime, RUNTIMES[runtime], arch)


if __name__ == "__main__":
    main()
