import agtermCore
import AppKit
import SwiftUI

/// Shows `WorkspaceSetupGuide` as a sheet on a window: once at first launch, and from File ▸ Set Up Workspaces….
@MainActor
enum WorkspaceSetupGuidePresenter {
    private static var checked = false

    /// The guide is local-only; tests never see it, and Skip, Cancel and Create each retire it.
    static func isDue(settings: AppSettings, store: AppStore?, uiTest: Bool, hosted: Bool) -> Bool {
        !uiTest && !hosted && settings.workspaceGuideDone != true && store?.isRemoteWindow != true
    }

    static func presentIfDue(actions: AppActions) {
        guard !checked, let settings = actions.settingsModel?.settings,
              isDue(settings: settings, store: actions.store, uiTest: ContentView.isUITestLaunch, hosted: agtermApp.isHostedUnitTest)
        else { return }
        // hop out of the scene task: a sheet begun inside it draws nothing. The latch is set only once one
        // shows, so a window not yet registered at the first `.task` leaves the next one to try.
        DispatchQueue.main.async {
            guard !checked, actions.showWorkspaceSetupGuide() else { return }
            checked = true
        }
    }

    /// Begins the guide on `window`; false when it already carries a sheet.
    static func present(on window: NSWindow, store: AppStore, settingsModel: SettingsModel) -> Bool {
        guard window.attachedSheet == nil else { return false }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let finish = { [weak window] in
            settingsModel.setWorkspaceGuideDone(true)
            window?.endSheet(sheet)
            // the view's closure holds the sheet; drop the view after its own button action returns
            DispatchQueue.main.async { sheet.contentViewController = nil }
        }
        let host = NSHostingController(rootView: WorkspaceSetupGuide(store: store, finish: finish))
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        window.beginSheet(sheet)
        return true
    }
}

extension AppActions {
    /// The one seam the menu and the first-launch trigger share. False when nothing was shown.
    @discardableResult
    func showWorkspaceSetupGuide() -> Bool {
        guard uiActionsEnabled, let store, !store.isRemoteWindow, let settingsModel,
              let windowID = library.activeWindowID,
              let window = NSApp.windows.first(where: { WindowRegistry.shared.windowID(for: $0) == windowID })
        else { return false }
        return WorkspaceSetupGuidePresenter.present(on: window, store: store, settingsModel: settingsModel)
    }
}
