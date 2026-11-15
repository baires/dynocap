# Homebrew formula for https://github.com/baires/homebrew-tap (install name: baires/tap/dynocap).
# The tap's update script rewrites Formula/dynocap.rb on each release. Keep its install method in step with this file.
# `url` is the versioned darwin-arm64 archive. `sha256` is the digest in the matching .sha256 asset.
# No bottle: pouring a bottle skips install, and install re-signs the CLI on the Mac that boots VMs.
class Dynocap < Formula
  desc "Local Linux microVM runtime for AI agents on macOS"
  homepage "https://github.com/baires/dynocap"
  url "https://github.com/baires/dynocap/releases/download/v0.0.0/dynocap-v0.0.0-darwin-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Apache-2.0"

  depends_on "e2fsprogs"
  depends_on macos: :ventura

  on_intel do
    odie "DynoCap publishes Apple Silicon (darwin-arm64) only."
  end

  def install
    if Hardware::CPU.intel?
      odie "DynoCap publishes Apple Silicon (darwin-arm64) only."
    end
    prefix.install Dir["*"]
    system "xattr", "-dr", "com.apple.quarantine", prefix
    system "codesign", "--sign", "-",
           "--entitlements", prefix/"entitlements/dynocap.entitlements",
           "--force", prefix/"bin/dynocap"
  end

  def caveats
    <<~EOS
      Run `dynocap doctor --fix` in your project after install.
      This formula re-signed the CLI with the bundled virtualization entitlement.
      The first runtime preparation needs Go 1.22 or newer.
    EOS
  end

  test do
    assert_match "dynocap", shell_output("#{bin}/dynocap --version")
  end
end
