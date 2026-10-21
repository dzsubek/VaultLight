# Template for the Homebrew cask in dzsubek/homebrew-tap (Casks/vaultlight.rb).
# The release workflow renders it with scripts/render-cask.sh, which replaces the
# `version` and `sha256` lines below; edit everything else here.
cask "vaultlight" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/dzsubek/homebrew-tap/releases/download/v#{version}/VaultLight-#{version}.zip",
      verified: "github.com/dzsubek/homebrew-tap/"
  name "VaultLight"
  desc "Unofficial quick-access panel for Bitwarden, not affiliated with Bitwarden"
  homepage "https://github.com/dzsubek/homebrew-tap"

  depends_on formula: "bitwarden-cli"
  depends_on macos: :sonoma

  app "VaultLight.app"

  uninstall quit: "hu.dzsubek.vaultlight"

  # `zap` cannot reach the data-protection keychain: choose "Lock and Forget" in the
  # menu bar, or Sign Out… in Settings, before uninstalling (see caveats).
  zap login_item: "VaultLight",
      trash:      [
        "~/Library/Application Support/VaultLight",
        "~/Library/Caches/hu.dzsubek.vaultlight",
        "~/Library/HTTPStorages/hu.dzsubek.vaultlight",
        "~/Library/Preferences/hu.dzsubek.vaultlight.plist",
        "~/Library/Saved Application State/hu.dzsubek.vaultlight.savedState",
      ]

  caveats <<~EOS
    VaultLight stores its session key in the macOS Keychain, and Homebrew cannot remove it.
    Before uninstalling, choose "Lock and Forget" from the VaultLight menu, or Sign Out… in
    Settings, so no session key is left behind.

    VaultLight is an unofficial client and is not affiliated with Bitwarden.
  EOS
end
