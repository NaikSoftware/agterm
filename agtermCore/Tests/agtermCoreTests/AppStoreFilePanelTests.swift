import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreFilePanelTests {
    @Test func filePanelDefaultsHiddenAt240() {
        let store = makeStore()

        #expect(!store.filePanelVisible)
        #expect(store.filePanelWidth == 240)
    }

    @Test func filePanelWidthClamps() {
        let store = makeStore()

        store.setFilePanelWidth(10)
        #expect(store.filePanelWidth == 160)
        store.setFilePanelWidth(9999)
        #expect(store.filePanelWidth == 560)
    }

    @Test func toggleFilePanelVisibleFlipsAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)

        store.toggleFilePanelVisible()

        #expect(store.filePanelVisible)
        #expect(persistence.load().filePanelVisible == true)
    }

    @Test func setFilePanelWidthWritesThroughToDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)

        store.setFilePanelWidth(300)

        #expect(persistence.load().filePanelWidth == 300)
    }

    @Test func treeReportsFilePanelState() {
        let store = makeStore()
        #expect(store.controlTree().filePanelVisible == false)
        #expect(store.controlTree().filePanelWidth == 240)

        store.setFilePanelVisible(true)
        store.setFilePanelWidth(300)

        #expect(store.controlTree().filePanelVisible == true)
        #expect(store.controlTree().filePanelWidth == 300)
    }
}
