cask "quotabar" do
  version "0.2.1"
  sha256 "a74083f4fb56dea2399bcbd4298d773e44a0458f188996062a4df3f9c70572a8"

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
