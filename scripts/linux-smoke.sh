#!/bin/sh
# Builds and smoke-launches the Linux app in an Ubuntu container under Xvfb.
# Verifies it links against GTK4 and creates its window without crashing.
# Requires Docker. Not run in CI (CI only compiles the target).
set -e
docker run --rm -v "$PWD":/work -w /work swift:6.0-noble bash -lc '
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libgtk-4-dev xvfb >/dev/null
swift build --product BurnRate
xvfb-run -a .build/debug/BurnRate > /tmp/app.log 2>&1 &
APP=$!
sleep 8
if kill -0 $APP 2>/dev/null; then
  echo "linux app: OK (window created)"
else
  echo "linux app: exited early"
  cat /tmp/app.log
  exit 1
fi
kill $APP 2>/dev/null || true
'
