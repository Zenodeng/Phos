import Foundation

enum AIModelSlot: String, CaseIterable, Identifiable {
    case lama
    case sky
    case depth
    case denoise
    case superRes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lama: return "LaMa 内容感知消除"
        case .sky: return "Core ML 天空分割"
        case .depth: return "DepthAnythingV2 景深"
        case .denoise: return "AI RAW 神经降噪"
        case .superRes: return "AI 2x 超分辨率"
        }
    }

    var fileName: String {
        switch self {
        case .lama: return "LaMa.mlmodelc"
        case .sky: return "SkySegmentation.mlmodelc"
        case .depth: return "DepthAnythingV2.mlmodelc"
        case .denoise: return "Denoise.mlmodelc"
        case .superRes: return "SuperRes.mlmodelc"
        }
    }

    var fallbackDescription: String {
        switch self {
        case .lama: return "未安装时自动使用内置 4 层 PatchMatch 消除"
        case .sky: return "未安装时自动使用地平线+梯度阻断零模型分割"
        case .depth: return "未安装时自动使用 Vision 显著性+人物混合单目深度"
        case .denoise: return "未安装时使用 Metal 线性 YCoCg 保边 RAW 降噪"
        case .superRes: return "未安装时使用 Lanczos 2x + Metal 结构张量锐化"
        }
    }

    var installScriptCommand: String? {
        switch self {
        case .lama: return "bash Scripts/install_lama_model.sh"
        case .depth: return "bash Scripts/install_depth_model.sh"
        default: return nil
        }
    }
}

struct AIModelSlotStatus: Identifiable {
    var slot: AIModelSlot
    var installed: Bool
    var sizeText: String?
    var modelPath: String
    var id: String { slot.rawValue }
}

/// 统一管理 P2/P3 端侧 Core ML 模型槽位的安装、状态查询与移除。
final class AIModelHub: @unchecked Sendable {
    static let shared = AIModelHub()

    var slots: [AIModelSlotStatus] {
        AIModelSlot.allCases.map { status(for: $0) }
    }

    var installedCount: Int {
        AIModelSlot.allCases.filter { isInstalled($0) }.count
    }

    func isInstalled(_ slot: AIModelSlot) -> Bool {
        switch slot {
        case .lama: return CoreMLInpaintingEngine.shared.isModelInstalled
        case .sky: return CoreMLSkyEngine.shared.isModelInstalled
        case .depth: return CoreMLDepthEngine.shared.isModelInstalled
        case .denoise: return CoreMLDenoiseEngine.shared.isModelInstalled
        case .superRes: return CoreMLSuperResEngine.shared.isModelInstalled
        }
    }

    func status(for slot: AIModelSlot) -> AIModelSlotStatus {
        let url: URL
        let installed: Bool
        var sizeText: String? = nil
        switch slot {
        case .lama:
            url = CoreMLInpaintingEngine.compiledLaMaURL
            installed = CoreMLInpaintingEngine.shared.isModelInstalled
            sizeText = CoreMLInpaintingEngine.shared.modelSummary ?? (installed ? folderSize(url) : nil)
        case .sky:
            url = CoreMLSkyEngine.shared.modelURL
            installed = CoreMLSkyEngine.shared.isModelInstalled
            if installed { sizeText = folderSize(url) }
        case .depth:
            url = CoreMLDepthEngine.shared.modelURL
            installed = CoreMLDepthEngine.shared.isModelInstalled
            sizeText = CoreMLDepthEngine.shared.modelSizeDescription
        case .denoise:
            url = CoreMLDenoiseEngine.shared.modelURL
            installed = CoreMLDenoiseEngine.shared.isModelInstalled
            sizeText = CoreMLDenoiseEngine.shared.modelSizeDescription
        case .superRes:
            url = CoreMLSuperResEngine.shared.modelURL
            installed = CoreMLSuperResEngine.shared.isModelInstalled
            sizeText = CoreMLSuperResEngine.shared.modelSizeDescription
        }
        return AIModelSlotStatus(slot: slot, installed: installed, sizeText: sizeText, modelPath: url.path)
    }

    func install(slot: AIModelSlot, from sourceURL: URL) throws {
        switch slot {
        case .lama: _ = try CoreMLInpaintingEngine.shared.installModel(from: sourceURL)
        case .sky: try CoreMLSkyEngine.shared.installModel(from: sourceURL)
        case .depth: try CoreMLDepthEngine.shared.installModel(from: sourceURL)
        case .denoise: try CoreMLDenoiseEngine.shared.installModel(from: sourceURL)
        case .superRes: try CoreMLSuperResEngine.shared.installModel(from: sourceURL)
        }
    }

    func remove(slot: AIModelSlot) throws {
        switch slot {
        case .lama: try CoreMLInpaintingEngine.shared.removeModel()
        case .sky: try CoreMLSkyEngine.shared.removeModel()
        case .depth: try CoreMLDepthEngine.shared.removeModel()
        case .denoise: try CoreMLDenoiseEngine.shared.removeModel()
        case .superRes: try CoreMLSuperResEngine.shared.removeModel()
        }
    }

    private func folderSize(_ url: URL) -> String? {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let f as URL in en {
            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return String(format: "%.1f MB", max(0.1, Double(total) / (1024.0 * 1024.0)))
    }
}
