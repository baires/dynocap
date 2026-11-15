# Homebrew formula for the tap OWNER/homebrew-tap.
# Install name: OWNER/tap/dynocap.
# Replace OWNER, the tag in `url`, and `sha256` when copying this file into that tap.
# `sha256` is the hex digest in dynocap-<tag>-darwin-arm64.tar.gz.sha256 from the GitHub release.
# `brew trust` is required because this formula runs codesign on the machine that will boot VMs.
class Dynocap < Formula
  desc "Local Linux microVM runtime for AI agents on macOS"
  homepage "https://github.com/OWNER/dynocap"
  url "https://github.com/OWNER/dynocap/releases/download/v0.0.0/dynocap-v0.0.0-darwin-arm64.tar.gz"
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
    EOS
  end

  test do
    assert_match "dynocap", shell_output("#{bin}/dynocap --version")
  end
end
