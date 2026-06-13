#!/bin/zsh
# Headless visual-snapshot harness for the MacSweep GUI.
#
# Compiles the FULL app source module (every Sources/**/*.swift except the CLI
# targets and MacSweepApp.swift, whose @main is replaced by the harness) together
# with scripts/RenderSnapshots.swift under -DSWIFT_PACKAGE (drops #Preview blocks
# whose macro is unavailable under CommandLineTools), then runs it to render every
# Feature screen to scripts/screenshots/.
#
# Works under CommandLineTools only — no Xcode, no xcodebuild required.
set -euo pipefail

REPO_ROOT="${0:A:h:h}"   # scripts/ -> repo root
cd "$REPO_ROOT"

SRC="MacSweep/Sources"
HARNESS="scripts/RenderSnapshots.swift"
OUTBIN="$(mktemp -d)/render-snapshots"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx13.0"

# App module file set: all GUI sources, minus CLI/CLIKit and the real @main owner.
FILES=("${(@f)$(find "$SRC" -name '*.swift' \
  -not -path "$SRC/CLI/*" \
  -not -path "$SRC/CLIKit/*" \
  -not -path "$SRC/App/MacSweepApp.swift" | sort)}")

print "Compiling ${#FILES} app sources + harness -> $OUTBIN"

swiftc \
  -parse-as-library \
  -DSWIFT_PACKAGE \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework SwiftUI -framework AppKit \
  -o "$OUTBIN" \
  "${FILES[@]}" "$HARNESS"

print "Compile OK. Rendering snapshots..."
"$OUTBIN"
print "Done. Screenshots in scripts/screenshots/"
