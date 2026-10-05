cask "spacewalk" do
  version "0.1.1"
  # Scripts/release.sh rewrites version and sha256 on every release. Until the first release
  # the checksum is a placeholder and the download URL does not resolve.
  sha256 "c6aa0b3431d22aa1d1a9e8ce8d4cbbc07f81744f884db7c9f359bb2687285b14"

  url "https://github.com/InsaneArts/Spacewalk/releases/download/v#{version}/Spacewalk.dmg"
  name "Spacewalk"
  desc "Instant, animated switching between macOS Spaces"
  homepage "https://github.com/InsaneArts/Spacewalk"

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
