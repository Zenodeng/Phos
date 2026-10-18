import Foundation

/// Rendering may finish its current frame; cancellation prevents publishing its file.
final class WorkspaceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled:Bool { lock.lock(); defer { lock.unlock() }; return value }
}

#if !PHOS_TESTING || PHOS_APP_TESTING
@MainActor extension AppState {
    var jobRunning:Bool { exportRunning || batchRunning || syncRunning }
    func cancelJobs() {
        jobCancellation?.cancel()
        status = "正在取消，等待当前照片处理结束…"
    }
    func startBatchExport(to directory:URL,onlyPicked:Bool) {
        guard !jobRunning else { return }
        batchTask = Task { [weak self] in await self?.batchExport(to:directory,onlyPicked:onlyPicked) }
    }
    func finishWindowWork() {
        temporaryPan = false
        if cropSession != nil { cancelCrop() }
        parameterEdits.finishCurrent()
        cancelMaskDrawing()
        if jobRunning { cancelJobs() }
        _ = saveCurrent()
        suspendPreviewWork()
    }
}

#endif
