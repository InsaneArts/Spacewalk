cask "spacewalk" do
  version "0.1.0"
  # Scripts/release.sh rewrites version and sha256 on every release. Until the first release
  # the checksum is a placeholder and the download URL does not resolve.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/tornikegomareli/Spacewalk/releases/download/v#{version}/Spacewalk.dmg"
  name "Spacewalk"
  desc "Instant, animated switching between macOS Spaces"
  homepage "https://github.com/tornikegomareli/Spacewalk"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Spacewalk.app"
  binary "#{appdir}/Spacewalk.app/Contents/MacOS/spacewalk-cli", target: "spacewalk"

  uninstall quit: "dev.tgomareli.spacewalk"

  zap trash: [
    "~/.config/spacewalk",
    "~/Library/Application Support/Spacewalk",
    "~/Library/Preferences/dev.tgomareli.spacewalk.plist",
  ]

  caveats do
    <<~EOS
      Spacewalk needs macOS 26.6 or newer: 26.0 to 26.5 blank the screen on a
      zero-travel Space switch. It asks for Screen Recording (to see your
      Spaces) and Accessibility (to switch them) on first launch.

      Settings live in ~/.config/spacewalk/config.toml. The spacewalk command
      is on your PATH: try `spacewalk next`.
    EOS
  end
end
