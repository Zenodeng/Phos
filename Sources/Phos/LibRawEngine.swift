import Foundation
import CoreImage
import CoreGraphics
import Darwin

/// 可选 LibRaw 动态解码引擎（零 App 体积膨胀）。
/// 通过 Darwin `dlopen` 按需加载本机安装的 `libraw.dylib`（或回退 `dcraw_emu` 命令行），
/// 提供 16-bit 线性输出、富士 X-Trans Markesteijn 3-pass 去马赛克与多通道高光色彩重建（Highlight Mode 5）。
final class LibRawEngine: @unchecked Sendable {
    static let shared = LibRawEngine()

    static let installCommand = "sh Scripts/install_libraw.sh"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Phos/LibRaw", isDirectory: true)
    }

    private struct ProcessedMemImage {
        var type: Int32      // LIBRAW_IMAGE_BITMAP = 2
        var height: UInt16
        var width: UInt16
        var colors: UInt16
        var bits: UInt16
        var dataSize: UInt32
        // followed immediately by flexible array `unsigned char data[1]`
    }

    private typealias FnInit = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    private typealias FnClose = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FnOpenFile = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
    private typealias FnUnpack = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias FnDcrawProcess = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias FnMakeMemImage = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer?
    private typealias FnClearMem = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FnVersion = @convention(c) () -> UnsafePointer<CChar>?
    private typealias FnSetInt = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias FnSetGamma = @convention(c) (UnsafeMutableRawPointer?, Int32, Float) -> Void

    private struct Symbols {
        let handle: UnsafeMutableRawPointer
        let path: String
        let version: String
        let librawInit: FnInit
        let librawClose: FnClose
        let librawOpenFile: FnOpenFile
        let librawUnpack: FnUnpack
        let librawDcrawProcess: FnDcrawProcess
        let librawMakeMemImage: FnMakeMemImage
        let librawClearMem: FnClearMem
        let setOutputBps: FnSetInt?
        let setOutputColor: FnSetInt?
        let setHighlight: FnSetInt?
        let setDemosaic: FnSetInt?
        let setNoAutoBright: FnSetInt?
        let setGamma: FnSetGamma?
    }

    private let lock = NSLock()
    private var cachedSymbols: Symbols?
    private var probed = false

    private static var candidateLibraryPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Phos/LibRaw/libraw.dylib",
            "\(home)/Library/Application Support/Phos/LibRaw/libraw_r.dylib",
            "/opt/homebrew/opt/libraw/lib/libraw.dylib",
            "/opt/homebrew/lib/libraw.dylib",
            "/usr/local/opt/libraw/lib/libraw.dylib",
            "/usr/local/lib/libraw.dylib"
        ]
    }

    private static var candidateCLIBinaries: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Phos/LibRaw/dcraw_emu",
            "/opt/homebrew/bin/dcraw_emu",
            "/usr/local/bin/dcraw_emu"
        ]
    }

    /// 供设置与检查器查询当前可用状态
    var isAvailable: Bool {
        resolveSymbols() != nil || resolveCLIBinary() != nil
    }

    var statusSummary: String {
        if let sym = resolveSymbols() {
            return "LibRaw \(sym.version)（动态库已就绪）"
        }
        if let cli = resolveCLIBinary() {
            return "LibRaw dcraw_emu（\(URL(fileURLWithPath: cli).lastPathComponent) 已就绪）"
        }
        return "未安装可选 LibRaw（保持零体积）"
    }

    var libraryPath: String? {
        resolveSymbols()?.path ?? resolveCLIBinary()
    }

    func rescan() {
        lock.lock()
        probed = false
        lock.unlock()
        _ = resolveSymbols()
    }

    private func resolveCLIBinary() -> String? {
        Self.candidateCLIBinaries.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func resolveSymbols() -> Symbols? {
        lock.lock()
        defer { lock.unlock() }
        if let s = cachedSymbols { return s }
        if probed { return nil }
        probed = true

        for path in Self.candidateLibraryPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }

            func sym<T>(_ name: String) -> T? {
                guard let p = dlsym(h, name) else { return nil }
                return unsafeBitCast(p, to: T.self)
            }

            guard let fInit: FnInit = sym("libraw_init"),
                  let fClose: FnClose = sym("libraw_close"),
                  let fOpen: FnOpenFile = sym("libraw_open_file"),
                  let fUnpack: FnUnpack = sym("libraw_unpack"),
                  let fProcess: FnDcrawProcess = sym("libraw_dcraw_process"),
                  let fMakeMem: FnMakeMemImage = sym("libraw_dcraw_make_mem_image"),
                  let fClearMem: FnClearMem = sym("libraw_dcraw_clear_mem") else {
                dlclose(h)
                continue
            }
            let fVer: FnVersion? = sym("libraw_version")
            let verStr = fVer?().map { String(cString: $0) } ?? "unknown"
            let loaded = Symbols(
                handle: h,
                path: path,
                version: verStr,
                librawInit: fInit,
                librawClose: fClose,
                librawOpenFile: fOpen,
                librawUnpack: fUnpack,
                librawDcrawProcess: fProcess,
                librawMakeMemImage: fMakeMem,
                librawClearMem: fClearMem,
                setOutputBps: sym("libraw_set_output_bps"),
                setOutputColor: sym("libraw_set_output_color"),
                setHighlight: sym("libraw_set_highlight"),
                setDemosaic: sym("libraw_set_demosaic"),
                setNoAutoBright: sym("libraw_set_no_auto_bright"),
                setGamma: sym("libraw_set_gamma")
            )
            cachedSymbols = loaded
            return loaded
        }
        return nil
    }

    /// 使用 LibRaw 解码 RAW 文件至 16-bit 线性浮点/整数 Core Image（进入 Phos 16-bit 扩展线性 Metal 管线）。
    /// - Parameters:
    ///   - url: RAW 文件路径
    ///   - highlightMode: 0=裁剪, 1=保留无裁, 2=混合, 5=多通道色彩重建（默认 5）
    ///   - linearCameraSpace: 为 true 且配合完整 DCP ColorMatrix 时输出未映射相机线性 RGB（output_color = 0），否则输出线性 sRGB（output_color = 1）
    func decode(_ url: URL, highlightMode: Int = 5, linearCameraSpace: Bool = false) -> CIImage? {
        if let sym = resolveSymbols() {
            if let ci = decodeViaDylib(sym, url: url, highlightMode: highlightMode, linearCameraSpace: linearCameraSpace) {
                return ci
            }
        }
        if let cli = resolveCLIBinary() {
            return decodeViaCLI(cli, url: url, highlightMode: highlightMode, linearCameraSpace: linearCameraSpace)
        }
        return nil
    }

    private func decodeViaDylib(_ sym: Symbols, url: URL, highlightMode: Int, linearCameraSpace: Bool) -> CIImage? {
        guard let handle = sym.librawInit(0) else { return nil }
        defer { sym.librawClose(handle) }

        // 16-bit 线性输出（gamma = 1, 1），关闭自动提亮以保真曝光宽容度，AHD/X-Trans Markesteijn 自动切换
        sym.setOutputBps?(handle, 16)
        sym.setOutputColor?(handle, linearCameraSpace ? 0 : 1) // 0=Raw Camera RGB, 1=sRGB
        sym.setGamma?(handle, 0, 1.0)
        sym.setGamma?(handle, 1, 1.0)
        sym.setNoAutoBright?(handle, 1)
        sym.setDemosaic?(handle, 3) // 3=AHD (Bayer) / Markesteijn 3-pass (X-Trans)
        let clampedHL = Int32(min(max(highlightMode, 0), 9))
        sym.setHighlight?(handle, clampedHL)

        let rcOpen = url.path.withCString { sym.librawOpenFile(handle, $0) }
        guard rcOpen == 0 else { return nil }
        guard sym.librawUnpack(handle) == 0 else { return nil }
        guard sym.librawDcrawProcess(handle) == 0 else { return nil }

        var errc: Int32 = 0
        guard let memPtr = sym.librawMakeMemImage(handle, &errc), errc == 0 else { return nil }
        defer { sym.librawClearMem(memPtr) }

        let header = memPtr.load(as: ProcessedMemImage.self)
        // type == 2 为 LIBRAW_IMAGE_BITMAP
        guard header.type == 2, header.width > 1, header.height > 1,
              header.colors == 3, header.bits == 16 else { return nil }

        let w = Int(header.width), h = Int(header.height)
        let expectedBytes = w * h * 3 * 2
        guard Int(header.dataSize) >= expectedBytes else { return nil }

        // struct libraw_processed_image_t 在 C 中前部 16 字节固定：
        // enum(4) + ushort height(2) + ushort width(2) + ushort colors(2) + ushort bits(2) + uint data_size(4) = 16 bytes
        let pixelBase = memPtr.advanced(by: 16).bindMemory(to: UInt16.self, capacity: w * h * 3)
        // 转为 RGBAf 扩展线性空间（保留无损 16-bit 精度并直接适配 MetalEngine 线性工作域）
        let pxCount = w * h
        var rgba = [Float](repeating: 0, count: pxCount * 4)
        let inv65535: Float = 1.0 / 65535.0
        for i in 0..<pxCount {
            let s = i * 3
            let d = i * 4
            rgba[d]     = Float(pixelBase[s])     * inv65535
            rgba[d + 1] = Float(pixelBase[s + 1]) * inv65535
            rgba[d + 2] = Float(pixelBase[s + 2]) * inv65535
            rgba[d + 3] = 1.0
        }

        let linearCS = CGColorSpace(name: CGColorSpace.linearSRGB) ?? Engine.workingColorSpace
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 16,
                       size: CGSize(width: w, height: h),
                       format: .RGBAf, colorSpace: linearCS)
    }

    private func decodeViaCLI(_ cliPath: String, url: URL, highlightMode: Int, linearCameraSpace: Bool) -> CIImage? {
        let tmpOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("phos-libraw-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: tmpOut) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = [
            "-T", "-6", "-W", "-w",
            "-g", "1", "1",
            "-q", "3",
            "-H", "\(min(max(highlightMode, 0), 9))",
            "-o", linearCameraSpace ? "0" : "1",
            "-Z", tmpOut.path,
            url.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: tmpOut.path) else { return nil }
            let linearCS = CGColorSpace(name: CGColorSpace.linearSRGB) ?? Engine.workingColorSpace
            return CIImage(contentsOf: tmpOut, options: [.colorSpace: linearCS])
        } catch {
            return nil
        }
    }
}
