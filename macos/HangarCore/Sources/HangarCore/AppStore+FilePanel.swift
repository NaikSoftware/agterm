import Foundation

extension AppStore {
    public static func clampFilePanelWidth(_ width: Double) -> Double {
        min(filePanelWidthMax, max(filePanelWidthMin, width))
    }

    public func setFilePanelVisible(_ visible: Bool) {
        guard filePanelVisible != visible else { return }
        filePanelVisible = visible
        save()
    }

    public func toggleFilePanelVisible() {
        setFilePanelVisible(!filePanelVisible)
    }

    public func setFilePanelWidth(_ width: Double) {
        let clamped = AppStore.clampFilePanelWidth(width)
        guard filePanelWidth != clamped else { return }
        filePanelWidth = clamped
        save()
    }
}
