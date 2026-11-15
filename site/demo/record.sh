#!/bin/sh
# Records the landing-page demo with VHS against the real CLI.
# Needs a Mac that can boot MicroVM guests, the signed release CLI, a prepared
# shell:1 runtime (microvm doctor --fix), and vhs (brew install vhs).
# Writes site/public/demo/microvm-workflow.{mp4,webm} and a poster frame.
set -eu

SITE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$SITE/.." && pwd)
CLI=${MICROVM_BIN:-"$REPO/.build/release/microvm"}

command -v vhs >/dev/null || { echo "vhs is not installed: brew install vhs" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed: brew install ffmpeg" >&2; exit 1; }
[ -x "$CLI" ] || { echo "No MicroVM CLI at $CLI. Run ./scripts/build-macos.sh or set MICROVM_BIN." >&2; exit 1; }

SOURCE_HOME=${MICROVM_HOME:-"$HOME/.microvm"}
[ -f "$SOURCE_HOME/runtime-catalog.json" ] || { echo "No prepared runtime in $SOURCE_HOME. Run microvm doctor --fix." >&2; exit 1; }

# The recording is published, so it runs in its own MICROVM_HOME: no personal paths
# appear in the output. APFS clones (cp -c) copy the prepared image and runtime instantly.
WORK=$(mktemp -d /tmp/microvm-demo.XXXX)
DEMO_HOME="$WORK/home"
DEMO_DIR="$WORK/demo-app"
stop() {
  pid=$(sed -n 's/.*"pid" *: *\([0-9]*\).*/\1/p' "$DEMO_HOME/daemon.json" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap stop EXIT
mkdir -p "$DEMO_HOME" "$DEMO_DIR"
cp -cR "$SOURCE_HOME/images" "$SOURCE_HOME/runtimes" "$SOURCE_HOME/runtime-catalog.json" "$DEMO_HOME/"
printf '# demo-app\n\nGreeting: hello from the host\n' >"$DEMO_DIR/README.md"

cd "$SITE"
PATH="$(dirname "$CLI"):$PATH" MICROVM_HOME="$DEMO_HOME" DEMO_DIR="$DEMO_DIR" \
  vhs demo/workflow.tape

# The poster is the last frame: the host README, still unchanged after finish.
ffmpeg -loglevel error -y -sseof -0.2 -i public/demo/microvm-workflow.mp4 \
  -frames:v 1 public/demo/microvm-workflow.png

ls -lh public/demo
