cask "quotabar" do
  version "0.2.4"
  sha256 "88b227b610fb2a7cda21c530f048c5bb4933993098564e76613e06c8dc924adc"

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
