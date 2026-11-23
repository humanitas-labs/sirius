cask "sirius" do
  version "0.4.6"
  sha256 "7537de027a2e4225a5cd56795edcc94ec1ef9d9d45ee3dccb3d3dcebc8a61c3b"

  url "https://github.com/humanitas-labs/sirius/releases/download/v#{version}/Sirius.dmg",
      verified: "github.com/humanitas-labs/sirius/"
  name "Sirius"
  desc "Speak or type to the agent CLI you already use"
  homepage "https://trysirius.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Sirius.app"

  uninstall quit: "com.humanitas.sirius"

  # ~/.agents is left alone: other agent tools share it.
  zap trash: [
    "~/Library/Application Support/Sirius",
    "~/Library/Caches/com.humanitas.sirius",
    "~/Library/HTTPStorages/com.humanitas.sirius",
    "~/Library/Logs/Sirius",
    "~/Library/Preferences/com.humanitas.sirius.plist",
  ]
end
