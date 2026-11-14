import Foundation

// One binary, three modes: the menu bar app, the root helper (--daemon) and the safe-state reset (--restore).
let arguments = CommandLine.arguments
if arguments.contains("--daemon") {
    runDaemon()
} else if arguments.contains("--restore") {
    runRestore()
} else {
    IzMacApp.main()
}
