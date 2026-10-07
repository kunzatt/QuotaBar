cask "quotabar" do
  version "0.1.5"
  sha256 "3b791875fae54d34c1df50976ce343e9d30876fd671e6b369b457aa0f4c23162"

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
