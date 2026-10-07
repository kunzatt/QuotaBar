cask "quotabar" do
  version "0.2.6"
  sha256 "42d6d5b8248bb99a659c4f45a8bec08e9e50fbe03779c98616b94b7e22168fbd"

  url "https://github.com/kunzatt/QuotaBar/releases/download/v#{version}/QuotaBar-#{version}-arm64.zip"
  name "QuotaBar"
  desc "Menu bar quota monitor for Codex and Claude Code accounts"
  homepage "https://github.com/kunzatt/QuotaBar"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "QuotaBar.app"

  zap trash: [
    "~/Library/Application Support/QuotaBar",
    "~/Library/Application Support/CodexBar",
  ]
end
