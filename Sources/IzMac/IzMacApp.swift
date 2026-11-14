import SwiftUI

struct IzMacApp: App {
    @StateObject private var model = Model()
    @StateObject private var charge = ChargeModel()
    @AppStorage("showCodex") private var showCodex = true
    @AppStorage("showClaude") private var showClaude = true
    @AppStorage("showPrayer") private var showPrayer = true
    @AppStorage("showBattery") private var showBattery = false

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(model).environmentObject(charge)
        } label: {
            Text(model.menuTitle(codex: showCodex, claude: showClaude, prayer: showPrayer, battery: showBattery))
        }
        .menuBarExtraStyle(.window)
    }
}
