import SwiftUI

/// A single persistent CanvasPane retains all existing crop and local-edit tools.
struct WorkspaceCanvas: View {
    @ObservedObject var session: WorkspaceSessionState
    var body: some View { CanvasPane(session: session).clipped() }
}
