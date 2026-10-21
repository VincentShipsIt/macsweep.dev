# Sourced by the zsh verification scripts after shell startup configuration.
# Keep custom Xcode selections; prefer full Xcode over CLT when both exist.
if [[ -n "${MACSWEEP_DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="$MACSWEEP_DEVELOPER_DIR"
elif [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == "/Library/Developer/CommandLineTools" \
        && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
