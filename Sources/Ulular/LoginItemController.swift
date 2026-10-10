import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var errorMessage: String?

    // Pending approval still represents a requested login item; switching off
    // must unregister it rather than trying to register it again.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not change Start at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
