import Foundation
import agtermCore

extension ControlServer {
    /// The open local window and workspace whose project folder owns `cwd`: the longest pin wins across windows, ties
    /// keep window order. Remote windows are never searched, their folders naming the other Mac.
    func pinOwner(of cwd: String) -> (store: AppStore, workspace: UUID)? {
        var best: (store: AppStore, workspace: UUID, length: Int)?
        for store in library.openIDs().compactMap({ library.store(for: $0) }) where store.remoteActions == nil {
            guard let id = store.workspaceID(owningFolder: cwd),
                  let length = store.workspaces.first(where: { $0.id == id })?.projectFolder?.count,
                  length > (best?.length ?? -1) else { continue }
            best = (store, id, length)
        }
        return best.map { ($0.store, $0.workspace) }
    }
}
