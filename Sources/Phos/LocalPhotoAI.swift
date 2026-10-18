import SwiftUI
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct PhotoAIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Explicit editing language: model output cannot overwrite unrelated edits.
struct PhotoAIPlan: Codable {
    struct Region: Codable {
        var kind: String
        var name: String?
        var target: String?
        var brightness: String?
        var inverted: Bool?
        var geometry: [String: Double]?
        var adjustments: [String: Double]
    }
    var summary: String
    var adjustments: [String: Double]
    var masks: [Region]
    var curves: [String:[[Double]]]?
    var hsl: [String:[String:Double]]?
    var grading: [String:[String:Double]]?
    static let keys: [String: WritableKeyPath<EditParams, Double>] = Dictionary(uniqueKeysWithValues: ParameterDescriptor.all.filter {
        !["cropX","cropY","cropW","cropH","straighten","perspectiveV","perspectiveH","bokehAmount","clutStrength","monoRed","monoGreen","monoBlue"].contains($0.id)
    }.map { ($0.id,$0.keyPath) })
    static let localKeys: [String: WritableKeyPath<LocalAdjust, Double>] = [
        "exposure": \.exposure, "contrast": \.contrast, "highlights": \.highlights,
        "shadows": \.shadows, "whites": \.whites, "blacks": \.blacks,
        "temperature": \.temperature, "tint": \.tint, "saturation": \.saturation,
        "texture": \.texture, "clarity": \.clarity, "dehaze": \.dehaze, "sharpen": \.sharpen, "denoise": \.denoise
    ]
    static func decode(_ text: String) throws -> Self {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if cleaned.hasPrefix("```"), let first = cleaned.firstIndex(of:"\n"), let last = cleaned.range(of:"```",options:.backwards), last.lowerBound > first {
            json = String(cleaned[cleaned.index(after:first)..<last.lowerBound])
        } else { json = cleaned }
        guard let data = json.data(using:.utf8), data.count < 40_000 else { throw PhotoAIError(message:"模型返回内容过长或为空，请重试。") }
        return try JSONDecoder().decode(Self.self,from:data)
    }
    func applying(to base: EditParams) throws -> EditParams {
        guard !summary.isEmpty, summary.count <= 1000, masks.count <= 4 else { throw PhotoAIError(message:"模型建议超出支持范围。") }
        func checked(_ value: Double, key: String, local: Bool = false) throws -> Double {
            let range = Self.range(key,local:local)
            guard value.isFinite, range.contains(value) else { throw PhotoAIError(message:"模型给出的 \(key) 超出范围，未应用修改。") }
            return value
        }
        var p = base
        for (key,value) in adjustments {
            guard let path = Self.keys[key] else { throw PhotoAIError(message:"不支持的调整：\(key)") }
            p[keyPath:path] = try checked(value,key:key)
        }
        for originalRegion in masks {
            let region = try Self.canonical(originalRegion)
            guard let kind = MaskKind(rawValue:region.kind), [.subject,.person,.foreground,.linear,.radial,.luminanceRange].contains(kind), (region.name?.count ?? 0) <= 80 else { throw PhotoAIError(message:"模型提出了不支持的蒙版。") }
            var m = Mask(); m.kind = kind; m.name = "AI · " + (region.name ?? kind.label); m.inverted = region.inverted ?? false
            let g = region.geometry ?? [:]
            let allowed: Set<String> = kind == .linear ? ["x0","y0","x1","y1","feather"] : kind == .radial ? ["x0","y0","radiusX","radiusY","feather"] : kind == .luminanceRange ? ["lumLow","lumHigh","lumSoft"] : []
            let required: Set<String> = kind == .linear ? ["x0","y0","x1","y1"] : kind == .radial ? ["x0","y0","radiusX","radiusY"] : kind == .luminanceRange ? ["lumLow","lumHigh"] : []
            guard required.isSubset(of:Set(g.keys)), Set(g.keys).isSubset(of:allowed), g.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw PhotoAIError(message:"蒙版坐标无效。") }
            m.x0 = g["x0"] ?? m.x0; m.y0 = g["y0"] ?? m.y0; m.x1 = g["x1"] ?? m.x1; m.y1 = g["y1"] ?? m.y1
            m.feather = g["feather"] ?? m.feather
            if kind == .linear {
                guard hypot(m.x1-m.x0,m.y1-m.y0) > 0.01 else { throw PhotoAIError(message:"线性蒙版范围太小。") }
                m.gradientVersion = 2
            }
            if kind == .radial {
                m.gradientVersion = 1
                m.radiusX = g["radiusX"] ?? 0.3; m.radiusY = g["radiusY"] ?? 0.3
                guard m.radiusX! >= 0.01, m.radiusY! >= 0.01 else { throw PhotoAIError(message:"径向蒙版范围太小。") }
            }
            m.lumLow = g["lumLow"] ?? m.lumLow; m.lumHigh = g["lumHigh"] ?? m.lumHigh; m.lumSoft = g["lumSoft"] ?? m.lumSoft
            guard m.lumLow <= m.lumHigh else { throw PhotoAIError(message:"亮度蒙版上下界无效。") }
            for (key,value) in region.adjustments {
                guard let path = Self.localKeys[key] else { throw PhotoAIError(message:"不支持的局部调整：\(key)") }
                m.adjust[keyPath:path] = try checked(value,key:key,local:true)
            }
            if !m.adjust.isNeutral { p.masks.append(m) }
        }
        return try advanced(to:p)
    }
}

private final class LocalOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One shared budget covers schema correction and rendered-direction correction.
@MainActor final class PhotoAIRequestBudget {
    private(set) var remaining = 2
    func take() throws {
        guard remaining > 0 else { throw PhotoAIError(message:"本次建议的修复次数已用完，请重新生成。") }
        remaining -= 1
    }
}

@MainActor final class PhotoAIService {
    static let shared = PhotoAIService()
    private var process: Process?
    private var log: FileHandle?
    private(set) var lastResponseText = ""
    private(set) var lastEditingAttempts = [String]()
    private let delegate = LocalOnlyRedirects()
    lazy var session = URLSession(configuration:.ephemeral,delegate:delegate,delegateQueue:nil)
    let endpoint = URL(string:"http://127.0.0.1:8765")!
    var directory: URL {
        URL(fileURLWithPath:UserDefaults.standard.string(forKey:"photoAIEnvironment") ?? NSHomeDirectory()+"/Library/Application Support/Phos/MLX",isDirectory:true)
    }
    init() {
        NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
    }
    func adapterDirectory() throws -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("PhotoAIAdapter",isDirectory:true)
        let adapter = bundled.flatMap { FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path) ? $0 : nil }
            ?? directory.appendingPathComponent("adapter",isDirectory:true)
        guard FileManager.default.fileExists(atPath:adapter.appendingPathComponent("manifest.json").path) else { return nil }
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:adapter.appendingPathComponent("manifest.json"))) as? [String:Any]
        func hash(_ url: URL) throws -> String { SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined() }
        guard manifest?["baseRepo"] as? String == "mlx-community/Qwen3-VL-4B-Instruct-4bit",
              manifest?["baseRevision"] as? String == "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b",
              try hash(directory.appendingPathComponent("model/config.json")) == manifest?["baseConfigSHA256"] as? String,
              try hash(adapter.appendingPathComponent("adapters.safetensors")) == manifest?["adapterSHA256"] as? String,
              FileManager.default.fileExists(atPath:adapter.appendingPathComponent("adapter_config.json").path) else {
            throw PhotoAIError(message:"微调适配器与底模不匹配或文件损坏，请安装配套模型。")
        }
        let legacy = manifest?["adapterSHA256"] as? String == "9311d57db7b28b48c1c38a56c73f274b0674313860dc180b51a3032a1914737a"
        if !legacy && (manifest?["serializationVersion"] as? String != Self.serializationVersion || manifest?["decoderFingerprint"] as? String != Self.decoderFingerprint) {
            throw PhotoAIError(message:"该适配器缺少已验证的输出协议，请安装配套版本。")
        }
        if let declared = manifest?["serializationVersion"] as? String, declared != Self.serializationVersion {
            throw PhotoAIError(message:"微调适配器的输出协议版本不匹配，未加载。")
        }
        if let declared = manifest?["decoderFingerprint"] as? String, declared != Self.decoderFingerprint {
            throw PhotoAIError(message:"微调适配器的解码协议指纹不匹配，未加载。")
        }
        return adapter
    }
    static let serializationVersion = "phos-json-compact-v1"
    static let decoderFingerprint = "cdc6da0726d1922e893b948d92251cc316262b80a644353db431c8cfbcdd5ab1"
    func ready() async -> Bool {
        var request = URLRequest(url:endpoint.appendingPathComponent("phos/protocol")); request.timeoutInterval = 2
        guard let (data,response) = try? await session.data(for:request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              value["baseRevision"] as? String == "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b",
              value["serializationVersion"] as? String == Self.serializationVersion,
              value["decoderFingerprint"] as? String == Self.decoderFingerprint,
              let implementation = Bundle.main.resourceURL?.appendingPathComponent("PhotoAIRuntime/photo_ai_protocol.py"),
              let implementationData = try? Data(contentsOf:implementation),
              value["protocolImplementationSHA256"] as? String == SHA256.hash(data:implementationData).map({ String(format:"%02x",$0) }).joined(),
              let config = try? Data(contentsOf:directory.appendingPathComponent("model/config.json")),
              value["baseConfigSHA256"] as? String == SHA256.hash(data:config).map({ String(format:"%02x",$0) }).joined() else { return false }
        do {
            let adapter = try adapterDirectory()
            let expected = try adapter.map { try Data(contentsOf:$0.appendingPathComponent("adapters.safetensors")) }
            let digest = expected.map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() }
            let configuration = try adapter.map { try Data(contentsOf:$0.appendingPathComponent("adapter_config.json")) }
            let configurationDigest = configuration.map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() }
            return value["adapterSHA256"] as? String == digest && value["adapterConfigSHA256"] as? String == configurationDigest
        } catch { return false }
    }
    func ensureReady() async throws {
        if await ready() { return }
        try Task.checkCancellation()
        if process?.isRunning != true {
            let python = directory.appendingPathComponent(".venv/bin/python")
            guard FileManager.default.fileExists(atPath:python.path) else { throw PhotoAIError(message:"找不到本地模型环境，请选择 Phos-MLX 文件夹。") }
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Phos-MLX.log")
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            FileManager.default.createFile(atPath:url.path,contents:nil); log = try FileHandle(forWritingTo:url)
            let p = Process(); p.executableURL = python
            guard let entry = Bundle.main.resourceURL?.appendingPathComponent("PhotoAIRuntime/photo_ai_server.py"), FileManager.default.fileExists(atPath:entry.path) else { throw PhotoAIError(message:"缺少配套的 AI 协议运行时，请重新安装 Phos。") }
            p.arguments = [entry.path,"--host","127.0.0.1","--port","8765","--model",directory.appendingPathComponent("model").path,"--max-tokens","1800","--prefill-step-size","512","--vision-cache-size","2"]
            if let adapter = try adapterDirectory() { p.arguments! += ["--adapter-path",adapter.path] }
            p.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
            p.environment = environment
            p.standardOutput = log; p.standardError = log
            try p.run(); process = p
        }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds:500_000_000)
            if await ready() { return }
            if process?.isRunning == false { break }
        }
        process?.terminate(); process = nil
        throw PhotoAIError(message:"本地服务未能启动，请检查 ~/Library/Logs/Phos-MLX.log。")
    }
    static func numericSchema(_ low: Double,_ high: Double, step: Double = 1) -> [String:Any] {
        let count = Int(((high-low)/step).rounded())
        return ["type":"number","enum":(0...count).map { ((low+Double($0)*step)*100).rounded()/100 }]
    }
    static var schema: [String:Any] {
        func adjustments(_ keys: [String], local: Bool) -> [String:Any] {
            var properties: [String:Any] = [:]
            for key in keys { let range = PhotoAIPlan.range(key,local:local); properties[key] = numericSchema(range.lowerBound,range.upperBound,step:key == "exposure" ? 0.05 : (range.upperBound <= 3 ? 0.01 : 1)) }
            return ["type":"object","properties":properties,"additionalProperties":false]
        }
        func region(_ kinds: [String], geometryKeys: [String] = [], requiredGeometry: [String] = []) -> [String:Any] {
            var properties: [String:Any] = ["kind":["type":"string","enum":kinds],"name":["type":"string","maxLength":80],"inverted":["type":"boolean"],"adjustments":adjustments(Array(PhotoAIPlan.localKeys.keys),local:true)]
            properties["target"] = ["type":"string","enum":kinds.contains("luminanceRange") ? ["highlights","shadows","region"] : (kinds.contains("person") ? ["subject","background"] : ["region"])]
            properties["brightness"] = ["type":"string","enum":["brighten","darken","unchanged"]]
            var required = ["kind","adjustments","target","brightness"]
            if !geometryKeys.isEmpty {
                let fields = Dictionary(uniqueKeysWithValues:geometryKeys.map { ($0,numericSchema(0,1,step:0.01)) })
                properties["geometry"] = ["type":"object","properties":fields,"required":requiredGeometry,"additionalProperties":false]
                required.append("geometry")
            }
            return ["type":"object","properties":properties,"required":required,"additionalProperties":false]
        }
        let regions = [region(["person","subject","foreground"]),region(["linear"],geometryKeys:["x0","y0","x1","y1","feather"],requiredGeometry:["x0","y0","x1","y1"]),region(["radial"],geometryKeys:["x0","y0","radiusX","radiusY","feather"],requiredGeometry:["x0","y0","radiusX","radiusY"]),region(["luminanceRange"],geometryKeys:["lumLow","lumHigh","lumSoft"],requiredGeometry:["lumLow","lumHigh"])]
        var result: [String:Any] = ["type":"object","properties":["summary":["type":"string","maxLength":160],"adjustments":adjustments(Array(PhotoAIPlan.keys.keys),local:false),"masks":["type":"array","items":["anyOf":regions],"maxItems":4]],"required":["summary","adjustments","masks"],"additionalProperties":false]
        var properties = result["properties"] as! [String:Any]
        func object(_ fields: [String:Any]) -> [String:Any] { ["type":"object","properties":fields,"additionalProperties":false] }
        func number(_ low: Double,_ high: Double) -> [String:Any] { numericSchema(low,high,step:high <= 1 ? 0.01 : 1) }
        let hsl = object(["hue":number(-60,60),"sat":number(-100,100),"lum":number(-100,100)])
        properties["hsl"] = object(Dictionary(uniqueKeysWithValues:PhotoAIPlan.bands.map { ($0,hsl) }))
        let grade = object(["hue":number(0,360),"sat":number(0,100),"lum":number(-100,100)])
        properties["grading"] = object(Dictionary(uniqueKeysWithValues:PhotoAIPlan.gradeKeys.keys.map { ($0,grade) }))
        let point: [String:Any] = ["type":"array","items":number(0,1),"minItems":2,"maxItems":2]
        let curve: [String:Any] = ["type":"array","items":point,"minItems":5,"maxItems":5]
        properties["curves"] = object(Dictionary(uniqueKeysWithValues:PhotoAIPlan.curveKeys.keys.map { ($0,curve) }))
        result["properties"] = properties
        return result
    }

    static func requestedMaskKinds(_ instruction: String) -> Set<String> {
        let text = instruction.lowercased()
        let names: [(String,[String])] = [("luminanceRange",["亮度范围","luminancerange"]),("linear",["线性渐变","线性蒙版"]),("radial",["径向渐变","径向蒙版"]),("person",["人物蒙版"]),("subject",["主体蒙版"]),("foreground",["前景蒙版"])]
        return Set(names.filter { $0.1.contains(where:text.contains) }.map(\.0))
    }
    static func schema(for instruction: String) -> [String:Any] {
        let kinds = requestedMaskKinds(instruction)
        var result = schema
        guard !kinds.isEmpty, var properties = result["properties"] as? [String:Any], var masks = properties["masks"] as? [String:Any], let items = masks["items"] as? [String:Any], let variants = items["anyOf"] as? [[String:Any]] else { return result }
        let selected: [[String:Any]] = variants.compactMap { original in
            guard var fields = original["properties"] as? [String:Any], var kind = fields["kind"] as? [String:Any], let choices = kind["enum"] as? [String] else { return nil }
            let allowed = choices.filter(kinds.contains)
            guard !allowed.isEmpty else { return nil }
            var variant = original; kind["enum"] = allowed; fields["kind"] = kind; variant["properties"] = fields
            return variant
        }
        masks["items"] = selected.count == 1 ? selected[0] : ["anyOf":selected]
        properties["masks"] = masks; result["properties"] = properties
        return result
    }

    private func request(jpeg: Data, prompt: String, schema: [String:Any], tokens: Int) async throws -> String {
        try await ensureReady()
        var request = URLRequest(url:endpoint.appendingPathComponent("v1/chat/completions")); request.httpMethod = "POST"; request.timeoutInterval = 240
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["model":directory.appendingPathComponent("model").path,"adapter_path":try adapterDirectory()?.path as Any? ?? NSNull(),"messages":[["role":"user","content":[["type":"text","text":prompt],["type":"image_url","image_url":["url":"data:image/jpeg;base64,"+jpeg.base64EncodedString()]]]]],"max_tokens":tokens,"temperature":0,"response_format":["type":"json_schema","json_schema":["name":"phos_edit","schema":schema]]],options:[.sortedKeys])
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PhotoAIError(message:"本地模型请求失败，请检查服务日志。") }
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        let responseBody = try JSONDecoder().decode(Response.self,from:data)
        guard let choice = responseBody.choices.first else { throw PhotoAIError(message:"模型没有返回建议。") }
        lastResponseText = choice.message.content
        guard choice.finish_reason != "length" else { throw PhotoAIError(message:"模型输出被截断，请简化要求后重试。") }
        return choice.message.content
    }
    func crop(jpeg: Data, instruction: String) async throws -> PhotoAICrop {
        if let explicit = try PhotoAICrop.explicit(instruction) { return explicit }
        let number = Self.numericSchema(0,1,step:0.01)
        let schema: [String:Any] = ["type":"object","properties":["x":number,"y":number,"width":number,"height":number],"required":["x","y","width","height"],"additionalProperties":false]
        let prompt = Self.cropPrompt(instruction:instruction)
        var feedback = ""
        var lastError: Error = PhotoAIError(message:"模型裁切建议未通过校验。")
        for _ in 0..<2 {
            try Task.checkCancellation()
            let text = try await request(jpeg:jpeg,prompt:prompt+feedback,schema:schema,tokens:180)
            do {
                let crop = try JSONDecoder().decode(PhotoAICrop.self,from:Data(text.utf8))
                _ = try crop.applying(to:EditParams())
                return crop
            } catch {
                lastError = error
                feedback = "\nInvalid previous crop: x+width and y+height must be <=1, width,height>=0.35, area>=0.4. Return a corrected box; use the full image if no safe crop is clear."
            }
        }
        throw lastError
    }
    func plan(jpeg: Data, instruction: String, base: EditParams, budget: PhotoAIRequestBudget? = nil) async throws -> PhotoAIPlan {
        lastEditingAttempts = []
        try Self.validateExplicitNumericRequest(instruction)
        let generationBudget = budget ?? PhotoAIRequestBudget()
        let prompt = try Self.editingPrompt(instruction:instruction,base:base)
        var feedback = ""
        var lastError: Error = PhotoAIError(message:"模型建议未通过校验。")
        for _ in 0..<2 {
            try Task.checkCancellation()
            try generationBudget.take()
            let text = try await request(jpeg:jpeg,prompt:prompt+feedback,schema:Self.editingSchema(instruction),tokens:1800)
            lastEditingAttempts.append(text)
            do {
                var plan = try PhotoAIPlan.decode(text).enforcing(instruction)
                let requested = Self.requestedMaskKinds(instruction)
                guard requested.isEmpty || plan.masks.allSatisfy({ requested.contains($0.kind) }) else { throw PhotoAIError(message:"模型未遵循指定的蒙版类型。") }
                plan.masks = try plan.masks.map(PhotoAIPlan.canonical)
                try Self.validateRequested(plan,base:base,instruction:instruction)
                return plan
            } catch {
                lastError = error
                feedback = "\nYour previous output failed validation: "+error.localizedDescription+" Return a corrected complete plan. Do not claim changes that leave slider/curve values unchanged."
                if error.localizedDescription.contains("曲线"), let hint = Self.curveRepairHint(instruction:instruction,base:base) { feedback += hint }
            }
        }
        throw lastError
    }
}

@MainActor final class PhotoAIEditor: ObservableObject {
    @Published var busy = false
    @Published var message = "用一句话描述想要的光线和色彩。所有分析均在本机完成。"
    @Published var before: CGImage?
    @Published var after: CGImage?
    @Published var candidate: EditParams?
    @Published var summary = ""
    @Published var detail = ""
    var base: EditParams?
    var photoID: UUID?
    private var task: Task<Void,Never>?
    private var requestID = UUID()
    func cancel() { requestID = UUID(); task?.cancel(); task = nil; busy = false }
    func generate(state: AppState, instruction: String, autoCrop: Bool = false) {
        cancel(); state.parameterEdits.finishCurrent(); state.cancelMaskDrawing()
        guard let source = state.source, let id = state.current?.id, !state.syncRunning else { return }
        let original = state.params, token = UUID(); requestID = token
        base = original; photoID = id; candidate = nil; after = nil; summary = ""; detail = ""
        busy = true; message = "正在启动本地模型并分析照片…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == token { busy = false } }
            do {
                try PhotoAIService.validateExplicitNumericRequest(instruction)
                let input = try await Task.detached(priority:.userInitiated) { try Self.preview(source:source,params:original) }.value
                try Task.checkCancellation(); before = input.0
                var working = original
                if autoCrop {
                    message = "正在分析构图并选择裁切范围…"
                    let crop = try await PhotoAIService.shared.crop(jpeg:input.1,instruction:instruction)
                    working = try crop.applying(to:original,imageSize:CGSize(width:input.0.width,height:input.0.height))
                    for mask in working.masks where mask.kind.usesVision { Engine.invalidateAIMask(id:mask.id) }
                    try Task.checkCancellation()
                }
                let cropped = try await Task.detached(priority:.userInitiated) { try Self.preview(source:source,params:working) }.value
                message = "正在分析色彩、曲线与局部光线…"
                let generationBudget = PhotoAIRequestBudget()
                var plan = try await PhotoAIService.shared.plan(jpeg:cropped.1,instruction:instruction,base:working,budget:generationBudget)
                try Task.checkCancellation()
                var proposed = try plan.applying(to:working)
                message = "正在渲染并核验蒙版明暗方向…"
                do { try await Task.detached(priority:.userInitiated) { try PhotoAIDirectionCheck.validate(source:source,base:working,proposed:proposed,regions:plan.masks) }.value }
                catch {
                    try Task.checkCancellation()
                    guard generationBudget.remaining > 0 else { throw error }
                    message = "局部效果未通过校验，正在修正建议…"
                    plan = try await PhotoAIService.shared.plan(jpeg:cropped.1,instruction:instruction+"\n上次建议未通过实际渲染校验："+error.localizedDescription+" 请修正选区和局部明暗方向，使用更明确的曝光调整。",base:working,budget:generationBudget)
                    proposed = try plan.applying(to:working)
                    try await Task.detached(priority:.userInitiated) { try PhotoAIDirectionCheck.validate(source:source,base:working,proposed:proposed,regions:plan.masks) }.value
                }
                let rendered = try await Task.detached(priority:.userInitiated) { try Self.preview(source:source,params:proposed) }.value
                try Task.checkCancellation()
                guard requestID == token, state.current?.id == id, state.params == original else { throw PhotoAIError(message:"照片或参数已变化，请重新生成建议。") }
                if proposed == original {
                    candidate = nil; after = rendered.0; summary = plan.summary; detail = "未修改参数"
                    message = "模型未建议改动，已保留当前效果。"; return
                }
                candidate = proposed; after = rendered.0; summary = plan.summary; detail = plan.detail + (working.cropX != original.cropX || working.cropY != original.cropY || working.cropW != original.cropW || working.cropH != original.cropH ? " · 已优化裁切" : ""); message = "建议已生成，应用后可用 ⌘Z 撤销。"
            } catch { if requestID == token { message = Task.isCancelled ? "已取消。" : error.localizedDescription } }
        }
    }
    nonisolated static func preview(source: CIImage, params: EditParams) throws -> (CGImage,Data) {
        let scale = min(1,1024/max(source.extent.width,source.extent.height))
        let result = Engine.render(source.transformed(by:CGAffineTransform(scaleX:scale,y:scale)),params)
        guard let cg = Engine.ctx.createCGImage(result,from:result.extent,format:.RGBA8,colorSpace:Engine.srgb) else { throw PhotoAIError(message:"无法生成预览。") }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw PhotoAIError(message:"无法编码预览。") }
        CGImageDestinationAddImage(writer,cg,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw PhotoAIError(message:"预览编码失败。") }
        return (cg,data as Data)
    }
}

struct PhotoAISheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = PhotoAIEditor()
    @State private var autoCrop = true
    @State private var instruction = "自然通透，平衡明暗，保留现场氛围；必要时用蒙版做局部调整。"
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label("AI 修图",systemImage:"sparkles.rectangle.stack").font(.title2.bold())
                Spacer(); Text("本地 · Qwen3-VL 4B · 微调实验版").font(.caption).foregroundStyle(.secondary)
            }
            Text(state.current?.url.lastPathComponent ?? "请先打开照片").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField("描述想要的效果…",text:$instruction,axis:.vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(editor.busy)
            Toggle("自动优化构图与裁切（实验性）",isOn:$autoCrop).disabled(editor.busy)
            HStack(spacing:12) {
                image(editor.before ?? state.preview,title:"当前效果")
                image(editor.after,title:"AI 建议预览")
            }
            if !editor.summary.isEmpty { Text(editor.summary).font(.callout).textSelection(.enabled) }
            if !editor.detail.isEmpty { Text(editor.detail).font(.caption).foregroundStyle(.secondary) }
            if let candidate = editor.candidate, let base = editor.base {
                Text(PhotoAIPlan.keys.keys.sorted().compactMap { key -> String? in
                    guard let path = PhotoAIPlan.keys[key], candidate[keyPath:path] != base[keyPath:path] else { return nil }
                    return "\(ParameterDescriptor.named(key).label) \(String(format:"%.2f",candidate[keyPath:path]))"
                }.joined(separator:" · ") + " · 新增蒙版 \(candidate.masks.count-base.masks.count)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack { if editor.busy { ProgressView().controlSize(.small) }; Text(editor.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("选择模型环境") { chooseEnvironment() }.disabled(editor.busy)
                Spacer()
                Button(editor.busy ? "取消分析" : "关闭") { if editor.busy { editor.cancel(); editor.message = "已取消。" } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("生成建议") { editor.generate(state:state,instruction:instruction,autoCrop:autoCrop) }.disabled(editor.busy || state.source == nil || state.previewing || state.syncRunning || instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("应用调整") {
                    state.parameterEdits.finishCurrent()
                    guard let candidate = editor.candidate, state.current?.id == editor.photoID, state.params == editor.base, !state.syncRunning else { editor.candidate = nil; editor.message = "照片或参数已变化，请重新生成建议。"; return }
                    state.showBefore = false; state.cropMode = false; state.selectedMask = nil
                    state.clearAutoTone(); state.commit(candidate); state.status = "已应用 AI 修图，可撤销"; dismiss()
                }.buttonStyle(.borderedProminent).disabled(editor.busy || editor.candidate == nil || state.current?.id != editor.photoID || state.params != editor.base || state.syncRunning)
            }
        }.padding(22).frame(width:720).onDisappear { editor.cancel() }
    }
    private func image(_ cg: CGImage?,title: String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius:10).fill(.black.opacity(0.12))
                if let cg { Image(decorative:cg,scale:1).resizable().scaledToFit().padding(4) }
                else { Image(systemName:"photo").font(.largeTitle).foregroundStyle(.tertiary) }
            }.frame(height:235).clipShape(RoundedRectangle(cornerRadius:10))
        }.frame(maxWidth:.infinity)
    }
    private func chooseEnvironment() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择包含 model 和 .venv 的模型环境文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.fileExists(atPath:url.appendingPathComponent(".venv/bin/python").path), FileManager.default.fileExists(atPath:url.appendingPathComponent("model/config.json").path) else { editor.message = "该文件夹缺少模型或启动脚本。"; return }
            UserDefaults.standard.set(url.path,forKey:"photoAIEnvironment"); editor.message = "本地模型环境已更新。"
        }
    }
}
