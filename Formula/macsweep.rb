# MacSweep — CLI-first macOS system cleaner.
#
# Distribution strategy (no Apple Developer account / code signing yet):
# build the `macsweep` CLI from source via SwiftPM. The Swift package lives in
# the `MacSweep/` subdirectory, so the install block builds from there.
#
# Install:
#   brew tap VincentShipsIt/macsweep https://github.com/VincentShipsIt/macsweep
#   brew install VincentShipsIt/macsweep/macsweep        # pinned stable release
#   brew install --HEAD VincentShipsIt/macsweep/macsweep # bleeding-edge from master
#
# RELEASE CHECKLIST — when cutting the next tag (vX.Y.Z): bump
# MacSweepVersion.current / MARKETING_VERSION to match, push the tag, then update
# the `url` + `sha256` below (compute with `brew fetch` or
# `shasum -a 256 <archive>.tar.gz`). Homebrew derives `version` from the tag in
# the url, so no explicit `version` line is needed.
class Macsweep < Formula
  desc "CLI-first macOS system cleaner (scan, clean, maintenance, malware, brew)"
  homepage "https://github.com/VincentShipsIt/macsweep"
  url "https://github.com/VincentShipsIt/macsweep/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "1fed3c5c608f65af99331a18125179e9be72e343b51e55a3eb87bc68f05a2549"
  license "MIT"
  head "https://github.com/VincentShipsIt/macsweep.git", branch: "master"

  depends_on macos: :ventura # macOS 13+ (matches Package.swift .macOS(.v13))

  def install
    # The SwiftPM package root is the `MacSweep/` subdirectory, not the repo
    # root. Build the release CLI product there, then install the binary.
    # `--disable-sandbox` is required: Homebrew's build sandbox blocks SwiftPM's
    # own network/cache access during dependency resolution.
    cd "MacSweep" do
      system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "macsweep"
      bin.install ".build/release/macsweep"
    end
  end

  test do
    # `macsweep version` prints "macsweep <semver>" to stdout and exits 0.
    output = shell_output("#{bin}/macsweep version")
    assert_match(/^macsweep \d+\.\d+\.\d+$/, output)
  end
end
