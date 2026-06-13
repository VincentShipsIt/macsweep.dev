# MacSweep — CLI-first macOS system cleaner.
#
# Distribution strategy (no Apple Developer account / code signing yet):
# build the `macsweep` CLI from source via SwiftPM. The Swift package lives in
# the `MacSweep/` subdirectory, so the install block builds from there.
#
# Install the development build now:
#   brew install --HEAD VincentShipsIt/macsweep/macsweep
# (after `brew tap VincentShipsIt/macsweep https://github.com/VincentShipsIt/macsweep`)
#
# RELEASE CHECKLIST — when a v1.x.y tag is cut, uncomment the `url`/`sha256`
# block below (compute the sha256 with `brew fetch` or `shasum -a 256`) so the
# formula installs a pinned, stable release instead of HEAD. Keep `version` in
# sync with `MacSweepVersion.current` / `MARKETING_VERSION`.
class Macsweep < Formula
  desc "CLI-first macOS system cleaner (scan, clean, maintenance, malware, brew)"
  homepage "https://github.com/VincentShipsIt/macsweep"
  license "MIT"
  head "https://github.com/VincentShipsIt/macsweep.git", branch: "master"

  # Stable release — fill in at release time:
  # url "https://github.com/VincentShipsIt/macsweep/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  # version "1.0.0"

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
