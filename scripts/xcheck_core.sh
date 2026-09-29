#!/usr/bin/env bash
# Differential check: the Rust core vs the real Swift BurnRateCore.
#
# Both sides print the same four vectors (token formatting, relative time, icon
# needle angles, severity tint ramp) and the outputs are diffed. This is what
# makes "parity" checkable rather than asserted: a divergence in the icon ramp
# is invisible in tests but obvious on the menu bar.
#
#   scripts/xcheck_core.sh            # compare
#   scripts/xcheck_core.sh --update   # accept the Swift output as expected
#
# Requires: Swift toolchain (the `swift` binary), cargo, python3. Skips cleanly
# with exit 0 if the Swift side cannot be built, so it is safe in CI.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="${TMPDIR:-/private/tmp}/burnrate-xcheck"

# ---- Swift side: a tiny executable that links the real BurnRateCore ---------
mkdir -p "$WORK/swift/Sources/xcheck"
cat > "$WORK/swift/Package.swift" <<EOF
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "xcheck",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$REPO")],
    targets: [.executableTarget(name: "xcheck", dependencies: [
        .product(name: "BurnRateCore", package: "ai-usage-tracker-mac-osx")
    ])]
)
EOF
cat > "$WORK/swift/Sources/xcheck/main.swift" <<'SWIFT'
import BurnRateCore
import Foundation

var checks: [(String, String)] = []

checks.append(("tokensFormatting", [0, 850, 999, 1000, 42300, 10000, 1250000,
                                    1_000_000_000, 3_600_000_000, 1_100_000_000_000]
    .map { TokenFormat.format($0) }.joined(separator: " ")))

let now = Date(timeIntervalSince1970: 1_700_000_000)
func rel(_ offset: TimeInterval) -> String {
    RelativeTime.format(now.addingTimeInterval(offset), now: now)
}
checks.append(("relativeTime", [rel(0), rel(-60), rel(1), rel(45 * 60), rel(3600),
                                rel(3600 + 30 * 60), rel(3 * 86400), rel(86399)]
    .joined(separator: " | ")))

func hex(_ rgb: (Double, Double, Double)) -> String {
    String(format: "#%02x%02x%02x", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255))
}
let levels: [Double?] = [100, 55, 50, 45, 20, 0, nil, 150, -20]
checks.append(("needleAngle", levels.map {
    String(format: "%.1f", StatusIcon.needleAngle(forRemaining: $0))
}.joined(separator: " ")))
checks.append(("tint", levels.map {
    let t = StatusIcon.tint(forRemaining: $0)
    return hex((t.top.red, t.top.green, t.top.blue)) + "/" + hex((t.bottom.red, t.bottom.green, t.bottom.blue))
}.joined(separator: " ")))

for (name, value) in checks { print("\(name): \(value)") }
SWIFT

# ---- Rust side: a tiny bin that links the real burnrate-core ---------------
mkdir -p "$WORK/rust/src"
cat > "$WORK/rust/Cargo.toml" <<EOF
[package]
name = "xcheck"
version = "0.1.0"
edition = "2021"

[dependencies]
burnrate-core = { path = "$REPO/crates/burnrate-core" }
EOF
cat > "$WORK/rust/src/main.rs" <<'RUST'
use burnrate_core::formatting::{RelativeTime, TokenFormat};
use burnrate_core::icon::StatusIcon;

fn main() {
    let tokens: Vec<i64> = vec![0, 850, 999, 1000, 42300, 10000, 1250000,
                               1_000_000_000, 3_600_000_000, 1_100_000_000_000];
    println!("tokensFormatting: {}", tokens.iter()
        .map(|n| TokenFormat::format(*n)).collect::<Vec<_>>().join(" "));

    let now: i64 = 1_700_000_000;
    let rel: Vec<String> = vec![0, -60, 1, 45 * 60, 3600, 3600 + 30 * 60, 3 * 86400, 86399]
        .iter().map(|o| RelativeTime::format(now + o, now)).collect();
    println!("relativeTime: {}", rel.join(" | "));

    let levels: Vec<Option<f64>> = vec![Some(100.0), Some(55.0), Some(50.0), Some(45.0),
                                       Some(20.0), Some(0.0), None, Some(150.0), Some(-20.0)];
    println!("needleAngle: {}", levels.iter()
        .map(|v| format!("{:.1}", StatusIcon::needle_angle(*v)))
        .collect::<Vec<_>>().join(" "));
    println!("tint: {}", levels.iter().map(|v| {
        let t = StatusIcon::tint(*v);
        format!("{}/{}", t.top.to_hex(), t.bottom.to_hex())
    }).collect::<Vec<_>>().join(" "));
}
RUST

# ---- Run both --------------------------------------------------------------
# This machine has Command Line Tools only, so pin an SDK the way scripts/test.sh does.
if [ -d /Library/Developer/CommandLineTools ]; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2*.sdk 2>/dev/null \
        | grep -v 'MacOSX\.sdk$' | sort -V | grep -v MacOSX27 | tail -1)
  export SDKROOT="$SDK"
fi

if ! (cd "$WORK/swift" && swift run -q xcheck > "$WORK/swift.txt" 2>"$WORK/swift.err"); then
  echo "skip: could not build the Swift side (see $WORK/swift.err)"
  head -5 "$WORK/swift.err" || true
  exit 0
fi
(cd "$WORK/rust" && cargo run -q > "$WORK/rust.txt" 2>"$WORK/rust.err") || {
  echo "FAIL: the Rust side did not run"
  tail -20 "$WORK/rust.err"
  exit 1
}

if [ "${1:-}" = "--update" ]; then
  cp "$WORK/swift.txt" "$WORK/expected.txt"
  echo "updated expected output from the Swift core:"
  cat "$WORK/expected.txt"
  exit 0
fi

if [ ! -f "$WORK/expected.txt" ]; then
  cp "$WORK/swift.txt" "$WORK/expected.txt"
  echo "recorded the Swift baseline; re-run to compare"
  exit 0
fi

echo "== rust vs swift =="
if diff -u "$WORK/swift.txt" "$WORK/rust.txt"; then
  echo "IDENTICAL"
else
  echo "DIVERGENT — the Rust core no longer matches the Swift core"
  exit 1
fi
