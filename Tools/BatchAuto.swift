// 批量「一键自动」命令行工具。
//
// 目的：对一整批照片执行与 Phos 界面里「自动」按钮完全相同的计算，
// 把结果写进各自的 .rawforge.json 伴生文件，之后在 Phos 里打开文件夹就能看到。
//
// 之所以要单独做：界面上一次只能处理一张，运动会这类一次几百张的批次
// 手工点不现实。计算路径与 AppState.runAutoTone(forcedScene:) 一致
// （Engine.decode → SceneClassifier.classify → AutoTone.analyze → AutoTone.apply），
// 所以出来的结果和手点没有差别。
//
// 用法：
//   BatchAuto plan   <图片或目录...>           只算不写，输出每张会怎么改 + 场景分布
//   BatchAuto apply  [选项] <图片或目录...>     计算并写入伴生文件
//
// 选项：
//   --scene <名称>      强制按某个题材计算，跳过场景识别（名称见 PhotoScene 的 rawValue）
//   --unify             用整批里出现最多的题材统一计算（低置信的图不再退回通用策略）
//   --strength <0...1>  自动强度，默认 1
//   --force             已有伴生文件且带调整时也覆盖（默认跳过，保护手动改过的图）
//   --dry               只打印将要写入的内容，不落盘
//
// 安全边界：只写 .rawforge.json，绝不改动原始照片。

import Foundation
import CoreImage

@main
struct BatchAuto {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            print("用法: BatchAuto plan|apply [选项] <图片或目录...>")
            exit(2)
        }
        args.removeFirst()

        var forcedSceneName: String?
        var unify = false
        var strength = 1.0
        var force = false
        var dry = false
        var outDir = ""
        var paths: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--scene":
                i += 1; forcedSceneName = args[safe: i]
            case "--out":
                i += 1; outDir = args[safe: i] ?? ""
            case "--unify":   unify = true
            case "--strength":
                i += 1; strength = Double(args[safe: i] ?? "") ?? 1
            case "--force":   force = true
            case "--dry":     dry = true
            default:          paths.append(args[i])
            }
            i += 1
        }
        guard !paths.isEmpty else { print("没有指定图片或目录"); exit(2) }

        let files = collect(paths)
        guard !files.isEmpty else { print("没有找到可处理的图片"); exit(2) }
        print("待处理 \(files.count) 张\n")

        // --unify 先扫一遍，取出现次数最多的题材作为全批统一题材。
        var unified: PhotoScene?
        if unify {
            var tally: [PhotoScene: Int] = [:]
            for url in files {
                guard let src = Engine.decode(url) else { continue }
                let g = SceneClassifier.classify(src)
                tally[g.scene, default: 0] += 1
            }
            unified = tally.max(by: { $0.value < $1.value })?.key
            if let u = unified { print("统一题材：\(u.label)（\(u.rawValue)）\n") }
        }
        let forced: PhotoScene? = forcedSceneName.flatMap { PhotoScene(rawValue: $0) } ?? unified

        if mode == "preview" {
            guard !outDir.isEmpty else { print("preview 需要 --out <出图目录>"); exit(2) }
            preview(files, URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath))
            exit(0)
        }

        var written = 0, skipped = 0, neutral = 0, failed = 0
        var sceneTally: [PhotoScene: Int] = [:]

        for (n, url) in files.enumerated() {
            let name = url.lastPathComponent
            guard let src = Engine.decode(url) else {
                print("[\(n + 1)/\(files.count)] 跳过（无法解码）：\(name)")
                failed += 1
                continue
            }
            let existing = SidecarStore.load(for: url)
            let base = existing?.params ?? EditParams()
            if let e = existing, !force, paramsLookEdited(e.params) {
                print("[\(n + 1)/\(files.count)] 跳过（已有调整，加 --force 覆盖）：\(name)")
                skipped += 1
                continue
            }

            let guess = forced.map { SceneGuess(scene: $0, confidence: 1) } ?? SceneClassifier.classify(src)
            sceneTally[guess.scene, default: 0] += 1
            let solution = AutoTone.analyze(src, params: base, scene: guess)

            let tag = String(format: "[%d/%d]", n + 1, files.count)
            if solution.isNeutral {
                print("\(tag) 画面已均衡，无需调整：\(name)")
                neutral += 1
                continue
            }
            let next = AutoTone.apply(solution, to: base, strength: strength)
            print(String(format: "%@ %@  场景 %@(%.2f)  ev%+.2f 对比%+.1f 高光%+.1f 阴影%+.1f 鲜艳%+.1f 去雾%+.1f%@",
                         tag, name as NSString, guess.scene.label as NSString, guess.confidence,
                         solution.exposure, solution.contrast, solution.highlights,
                         solution.shadows, solution.vibrance, solution.dehaze,
                         solution.highlightMaskExposure < 0 ? "  [含压高光蒙版]" : ""))

            if mode == "plan" || dry { continue }

            var s = existing ?? Sidecar(params: base)
            s.params = next
            s.version = 2
            if SidecarStore.save(s, for: url) {
                written += 1
            } else {
                print("     写入失败：\(name)")
                failed += 1
            }
        }

        print("\n———— 汇总 ————")
        for (scene, count) in sceneTally.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-8@ %d 张", scene.label as NSString, count))
        }
        print("写入 \(written)　跳过（已有调整）\(skipped)　无需调整 \(neutral)　失败 \(failed)")
    }

    /// 抽样出前后对比图，用来肉眼确认整批的风格是否统一。
    /// 出图用伴生文件里已经写好的参数，所以「后」就是 Phos 打开后会看到的样子。
    static func preview(_ files: [URL], _ outDir: URL) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let maxSide: CGFloat = 1600
        // 均匀抽样，最多 16 张：看风格够不够统一，这个数量够了。
        let step = max(1, files.count / 16)
        let picked = stride(from: 0, to: files.count, by: step).map { files[$0] }
        print("抽样 \(picked.count) 张，出图到 \(outDir.path)")
        for (i, url) in picked.enumerated() {
            guard let src = Engine.decode(url) else { print("跳过（无法解码）：\(url.lastPathComponent)"); continue }
            guard let after = SidecarStore.load(for: url)?.params else {
                print("跳过（还没有伴生文件，先跑 apply）：\(url.lastPathComponent)"); continue
            }
            let scale = min(1, maxSide / max(src.extent.width, src.extent.height))
            func out(_ base: String) -> CIImage {
                let img = src
                return scale < 1 ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : img
            }
            let small = out("s")
            var settings = ExportSettings(); settings.format = "jpg"; settings.quality = 0.9
            let before = Engine.render(out("b"), EditParams())
            let afterImg = Engine.render(small, after)
            let stem = String(format: "%02d-%@", i, (url.deletingPathExtension().lastPathComponent as NSString))
            do {
                try Engine.write(before, to: outDir.appendingPathComponent("\(stem)-before.jpg"), settings: settings)
                try Engine.write(afterImg, to: outDir.appendingPathComponent("\(stem)-after.jpg"), settings: settings)
            } catch {
                print("出图失败 \(stem): \(error.localizedDescription)")
            }
            print("  \(stem)  ok")
        }
    }

    /// 判断这张图是否已经被改过 —— 用来避免把用户手动调好的图覆盖掉。
    static func paramsLookEdited(_ p: EditParams) -> Bool {
        p.exposure != 0 || p.contrast != 0 || p.highlights != 0 || p.shadows != 0
            || p.whites != 0 || p.blacks != 0 || p.clarity != 0 || p.texture != 0
            || p.dehaze != 0 || p.vibrance != 0 || p.saturation != 0
            || p.temperature != 0 || p.tint != 0
            || p.whiteBalanceGains != [1, 1, 1]
            || !p.masks.isEmpty || p.cropW != 0 || p.rotation != 0 || p.denoise != 0
    }

    static func collect(_ paths: [String]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var isDir: ObjCBool = false
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let items = try? fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                let imgs = items.filter { Engine.browseSet.contains($0.pathExtension.lowercased()) }
                out.append(contentsOf: imgs.sorted { $0.lastPathComponent < $1.lastPathComponent })
            } else if Engine.browseSet.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        // 同一张图可能被重复传入（目录 + 单文件）
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
