import agtermCore
import Foundation

extension ControlServer: SessionTyping {
    func typeLine(_ line: String, into sessionID: UUID, store: AppStore) async -> Bool {
        await injectText(line + "\n", into: sessionID, store: store, select: false, pane: .left).ok
    }
}
