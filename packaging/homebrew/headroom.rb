# Homebrew cask template. scripts/render-cask.py fills the @…@ values from
# VERSION, packaging/app.env and the release DMG's SHA-256, for the tap repo
# (HOMEBREW_TAP in packaging/app.env) at Casks/@CASK_TOKEN@.rb.
cask "@CASK_TOKEN@" do
  version "@MARKETING_VERSION@"
  sha256 "@DMG_SHA256@"

  url "https://github.com/@GITHUB_REPO@/releases/download/v#{version}/@APP_NAME@-#{version}.dmg"
  name "@APP_NAME@"
  desc "Memory pressure and disk space monitor for the notch and menu bar"
  homepage "https://github.com/@GITHUB_REPO@"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :ventura"

  app "@APP_NAME@.app"

  uninstall quit: "@BUNDLE_ID@"

  zap trash: [
    "~/Library/Application Support/@APP_NAME@",
    "~/Library/Caches/@BUNDLE_ID@",
    "~/Library/HTTPStorages/@BUNDLE_ID@",
    "~/Library/Preferences/@BUNDLE_ID@.plist",
    "~/Library/Saved Application State/@BUNDLE_ID@.savedState",
  ]
end
