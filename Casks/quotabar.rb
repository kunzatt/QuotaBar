cask "quotabar" do
  version "0.2.5"
  sha256 "004014c045639358a0c234b44ae54dacb9bb0c0a04f9694fe959f6ae7f57ece3"

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
