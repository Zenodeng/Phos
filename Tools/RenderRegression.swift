import Foundation
import CoreImage

@main
struct RenderRegression {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extent = CGRect(x: 0, y: 0, width: 640, height: 480)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 640, y: 480),
            "inputColor0": CIColor(red: 0.04, green: 0.55, blue: 0.95),
            "inputColor1": CIColor(red: 0.98, green: 0.12, blue: 0.03)
        ])!.outputImage!.cropped(to: extent)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.2, green: 0.8, blue: 0.3),
            "inputColor1": CIColor(red: 0.9, green: 0.2, blue: 0.7),
            "inputWidth": 53
        ])!.outputImage!.cropped(to: extent)
        let source = gradient.applyingFilter("CISoftLightBlendMode",
                                             parameters: [kCIInputBackgroundImageKey: checker])
        var cases: [(String, EditParams)] = [("neutral", EditParams())]
        func add(_ name: String, _ edit: (inout EditParams) -> Void) {
            var params = EditParams()
            edit(&params)
            cases.append((name, params))
        }
        add("tone") { p in
            p.exposure = 0.7; p.contrast = 18; p.highlights = -35; p.shadows = 23
            p.temperature = 12; p.tint = -7; p.whites = 9; p.blacks = -11
            p.vibrance = 20; p.saturation = -6; p.clarity = 12; p.dehaze = 8
        }
        add("curve-grade") { p in
            p.curve.points = [[0, 0], [0.3, 0.2], [0.7, 0.85], [1, 1]]
            p.curveR.points = [[0, 0], [0.5, 0.6], [1, 1]]
            p.lumaCurve.points = [[0, 0], [0.5, 0.55], [1, 1]]
            p.gradeShadow.hue = 210; p.gradeShadow.sat = 22
            p.gradeHigh.hue = 40; p.gradeHigh.sat = 12; p.refineSat = 20
            p.calibShadowTint = 8
        }
        add("hsl") { p in p.hsl.blue.sat = -40; p.hsl.red.hue = 18; p.hsl.green.lum = 14 }
        add("detail") { p in
            p.sharpen = 0.8; p.sharpenMask = 0.4; p.denoise = 30; p.denoiseColor = 24
            p.halation = 30; p.purpleFringe = 20
        }
        add("geometry") { p in
            p.cropX = 0.1; p.cropY = 0.1; p.cropW = 0.75; p.cropH = 0.7
            p.rotation = 90; p.flipped = true; p.straighten = 3
            p.perspectiveV = 5
        }
        add("mono-calibration") { p in p.mono = true; p.primRed.hue = 10; p.primBlue.sat = 15 }
        for kind in [MaskKind.radial, .linear, .brush, .colorRange, .luminanceRange, .depth] {
            add("mask-\(kind.rawValue)") { p in
                var mask = Mask()
                mask.kind = kind
                mask.adjust.exposure = 1.3
                mask.strokes = [Stroke(pts: [[0.3, 0.4], [0.4, 0.5], [0.5, 0.6]], radius: 0.1, feather: 0.3)]
                mask.sampleRGB = [0.3, 0.6, 0.7]
                p.masks = [mask]
                if kind == .depth { p.bokehAmount = 25 }
            }
        }
        if let name = CLUTLibrary.shared.list().first {
            add("film") { p in p.clutName = name; p.clutStrength = 0.73 }
        }
        for (name, params) in cases {
            let start = Date()
            let image = Engine.render(source, params)
            let bounds = image.extent.integral
            let width = Int(bounds.width), height = Int(bounds.height)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            Engine.ctx.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds,
                              format: .RGBA8, colorSpace: Engine.srgb)
            precondition(Set(bytes).count > 32, "Empty/invalid render: \(name). Run with access to macOS graphics services.")
            try Data(bytes).write(to: directory.appendingPathComponent("\(name)-\(width)x\(height).rgba"))
            if let cube = CurveCube.filter(params)?.value(forKey: "inputCubeData") as? Data {
                try cube.write(to: directory.appendingPathComponent("\(name).cube"))
            }
            print(String(format: "%@ %.1f ms", name, Date().timeIntervalSince(start) * 1000))
        }
        let start = Date()
        for _ in 0..<100 {
            _ = RangeCube.colorMask(sample: [0.3, 0.6, 0.7], tolerance: 0.2)
            _ = RangeCube.luminanceMask(low: 0.2, high: 0.7, soft: 0.1)
        }
        print(String(format: "Repeated range LUTs (100 pairs): %.1f ms", Date().timeIntervalSince(start) * 1000))
        if CommandLine.arguments.count > 2 {
            let baseline = URL(fileURLWithPath: CommandLine.arguments[2])
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "rgba" || file.pathExtension == "cube" {
                let before = try Data(contentsOf: baseline.appendingPathComponent(file.lastPathComponent))
                let after = try Data(contentsOf: file)
                precondition(before == after, "Pixel mismatch: \(file.lastPathComponent)")
            }
            print("PASS: all \(cases.count) render cases are byte-identical to baseline.")
        }
    }
}
