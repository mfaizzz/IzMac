import SwiftUI

@main
struct IzMacApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
