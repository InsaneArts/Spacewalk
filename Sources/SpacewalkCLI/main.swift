import Foundation
import SpacewalkCore

let usage = """
spacewalk — animated switching between macOS Spaces

usage: spacewalk switch <n>       go to the n-th space of the display under the cursor
       spacewalk next | prev      neighbouring space
       spacewalk back-and-forth   previous space
       spacewalk status           is Spacewalk.app running? Prints capture state and recent timings
       spacewalk preview          play the current effect on screen without switching
       spacewalk overview         show every Space as a picture; arrows, digits or typing jump
       spacewalk name <n> <text>  name the n-th Space (empty text clears it)
       spacewalk settings         open the Settings window
       spacewalk bind arrows      take over ⌃← and ⌃→ for previous and next space
       spacewalk bind digits      bind ⌃1 to ⌃9 to spaces 1 to 9
       spacewalk bind swipes      replace three-finger swipes with Spacewalk's transition
       spacewalk unbind <what>    undo one of the above
       spacewalk effect <name>    instant|slide|depth|tilt|carousel|fade|zoom|cube|flip|swap|reveal|stack
       spacewalk slowmo <x>       slow every transition x times (1 restores)
       spacewalk duration <ms>    set the transition duration
       spacewalk set <key> on|off pill, sound, haptic, interactive, predictive, eager, animations,
                              indicator, buttons, edgescroll, wrap, alldisplays, bar, bartop, gestureoverview
       spacewalk columns <n>      virtual grid width (0 = one row, 1 = a vertical stack)
       spacewalk export <file>    write all settings as JSON
       spacewalk import <file>    read settings from JSON
       spacewalk set haptic <s>   light | medium | strong | double (also clicks once to try it)
       spacewalk snapshot <path>  save a PNG of the main display, overlay included
       spacewalk snapshot <path>|settings  save a PNG of the settings window alone
       spacewalk render <dir>     render the current effect offscreen, one PNG per sampled frame
                              (dir|full for screen size, dir|scrub|36 for 36 evenly spaced frames)
                              (dir|full for screen size, dir|scrub|36 for 36 evenly spaced frames)
       spacewalk wallpapers <dir> save the wallpaper Spacewalk has captured for every space
"""

let words = Array(CommandLine.arguments.dropFirst())
if words.isEmpty || words[0] == "-h" || words[0] == "--help" {
    print(usage)
    exit(0)
}
if words[0] == "status" {
    guard SpacewalkIPC.appIsRunning else { print("not running"); exit(1) }
    if let text = try? String(contentsOf: SpacewalkIPC.statusFile, encoding: .utf8) { print(text) } else { print("running (no status yet)") }
    exit(0)
}
if (words[0] == "bind" || words[0] == "unbind"), words.count > 1, ["arrows", "digits", "swipes"].contains(words[1]) {
    guard SpacewalkIPC.appIsRunning else { print("Spacewalk.app is not running"); exit(1) }
    SpacewalkIPC.sendCommand("\(words[0])-\(words[1])")
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
if words[0] == "set", words.count > 2 {
    guard SpacewalkIPC.appIsRunning else { print("Spacewalk.app is not running"); exit(1) }
    SpacewalkIPC.sendCommand("set:\(words[1])=\(words[2])")
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
if ["effect", "slowmo", "snapshot", "duration", "render", "wallpapers", "columns", "export", "import"].contains(words[0]), words.count > 1 {
    guard SpacewalkIPC.appIsRunning else { print("Spacewalk.app is not running"); exit(1) }
    let value = ["snapshot", "render", "wallpapers", "export", "import"].contains(words[0]) ? URL(fileURLWithPath: words[1]).path : words[1]
    SpacewalkIPC.sendCommand("\(words[0]):\(value)")
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
if words[0] == "name", words.count > 2 {
    guard SpacewalkIPC.appIsRunning else { print("Spacewalk.app is not running"); exit(1) }
    SpacewalkIPC.sendCommand("name:\(words[1])=\(words.dropFirst(2).joined(separator: " "))")
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
if ["preview", "settings", "overview", "fix-rearrange"].contains(words[0]) {
    guard SpacewalkIPC.appIsRunning else { print("Spacewalk.app is not running"); exit(1) }
    SpacewalkIPC.sendCommand(words[0] == "settings" ? "open-settings" : words[0])
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    exit(0)
}
guard let target = SpacewalkIPC.parseTarget(words) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
guard SpacewalkIPC.appIsRunning else {
    FileHandle.standardError.write(Data("spacewalk: Spacewalk.app is not running\n".utf8))
    exit(1)
}
SpacewalkIPC.send(target)
// Give the notification a moment to leave the process.
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
exit(0)
