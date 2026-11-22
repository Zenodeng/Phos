import SwiftUI
import MetalKit
import CoreImage
import QuartzCore

/// HDR / 广色域 (RGBA16Float + Extended Linear Display P3 + EDR) 视口级实时画布视图。
/// 始终按视口尺寸分配 Metal Drawable（1:1 放大也不爆显存），底层保留 `CGImage` 兜底渲染。
struct MetalCanvasView: View {
    let metalImage: CIImage?
    let fallbackCG: CGImage
    let viewportSize: CGSize
    let imageRect: CGRect
    let edrEnabled: Bool
    let clippingWarning: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: fallbackCG, scale: 1)
                .resizable()
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)

            if let metalImage, MetalEngine.shared.isAvailable,
               viewportSize.width > 1, viewportSize.height > 1,
               imageRect.width > 1, imageRect.height > 1 {
                MetalCanvasRepresentable(
                    ciImage: metalImage,
                    viewportSize: viewportSize,
                    imageRect: imageRect,
                    edrEnabled: edrEnabled,
                    clippingWarning: clippingWarning
                )
                .frame(width: viewportSize.width, height: viewportSize.height)
                .allowsHitTesting(false)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .clipped()
    }
}

private struct MetalCanvasRepresentable: NSViewRepresentable {
    let ciImage: CIImage
    let viewportSize: CGSize
    let imageRect: CGRect
    let edrEnabled: Bool
    let clippingWarning: Bool

    func makeNSView(context: Context) -> MetalCanvasMTKView {
        let view = MetalCanvasMTKView(frame: CGRect(origin: .zero, size: viewportSize), device: MetalEngine.shared.device)
        view.configure(ciImage: ciImage, viewportSize: viewportSize, imageRect: imageRect,
                       edrEnabled: edrEnabled, clippingWarning: clippingWarning)
        return view
    }

    func updateNSView(_ nsView: MetalCanvasMTKView, context: Context) {
        nsView.configure(ciImage: ciImage, viewportSize: viewportSize, imageRect: imageRect,
                         edrEnabled: edrEnabled, clippingWarning: clippingWarning)
    }
}

@MainActor
final class MetalCanvasMTKView: MTKView, MTKViewDelegate {
    private var currentImage: CIImage?
    private var viewportSize: CGSize = .zero
    private var imageRect: CGRect = .zero
    private var edrEnabled = true
    private var clippingWarning = false
    private var lastSignature = ""

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MetalEngine.shared.device)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MetalEngine.shared.device
        commonInit()
    }

    private func commonInit() {
        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = Engine.displayColorSpace
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        wantsLayer = true
        layer?.isOpaque = false
        if let ml = layer as? CAMetalLayer {
            ml.wantsExtendedDynamicRangeContent = edrEnabled
            ml.colorspace = Engine.displayColorSpace
            ml.pixelFormat = .rgba16Float
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(ciImage: CIImage, viewportSize: CGSize, imageRect: CGRect, edrEnabled: Bool, clippingWarning: Bool) {
        let ext = ciImage.extent
        let sig = "\(ObjectIdentifier(ciImage).hashValue)-\(Int(ext.width))x\(Int(ext.height))-\(Int(viewportSize.width.rounded()))x\(Int(viewportSize.height.rounded()))-\(String(format: "%.2f,%.2f,%.2f,%.2f", imageRect.minX, imageRect.minY, imageRect.width, imageRect.height))-\(edrEnabled)-\(clippingWarning)"
        guard sig != lastSignature else { return }
        lastSignature = sig
        self.currentImage = ciImage
        self.viewportSize = viewportSize
        self.imageRect = imageRect
        self.edrEnabled = edrEnabled
        self.clippingWarning = clippingWarning
        if let ml = layer as? CAMetalLayer {
            ml.wantsExtendedDynamicRangeContent = edrEnabled
            ml.colorspace = Engine.displayColorSpace
        }
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard var img = currentImage,
              viewportSize.width > 1, viewportSize.height > 1,
              drawableSize.width > 1, drawableSize.height > 1,
              imageRect.width > 1, imageRect.height > 1,
              let drawable = currentDrawable,
              let cmd = MetalEngine.shared.commandQueue?.makeCommandBuffer() else { return }

        if clippingWarning {
            img = MetalClippingOverlayKernel.apply(img)
        }

        let ext = img.extent
        guard ext.width > 0, ext.height > 0 else { return }

        let scaleX = drawableSize.width / max(viewportSize.width, 1)
        let scaleY = drawableSize.height / max(viewportSize.height, 1)
        let destX = imageRect.minX * scaleX
        let destY = (viewportSize.height - imageRect.maxY) * scaleY
        let destW = imageRect.width * scaleX
        let destH = imageRect.height * scaleY

        let toOrigin = CGAffineTransform(translationX: -ext.minX, y: -ext.minY)
        let toScaled = CGAffineTransform(scaleX: destW / ext.width, y: destH / ext.height)
        let toDest = CGAffineTransform(translationX: destX, y: destY)
        let transformed = img.transformed(by: toOrigin.concatenating(toScaled).concatenating(toDest))

        let targetRect = CGRect(origin: .zero, size: drawableSize)
        let composed = transformed.composited(over: CIImage.clear.cropped(to: targetRect)).cropped(to: targetRect)

        let dest = CIRenderDestination(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: .rgba16Float,
            commandBuffer: cmd
        ) {
            drawable.texture
        }
        dest.colorSpace = Engine.displayColorSpace
        dest.isFlipped = true
        dest.alphaMode = .premultiplied

        do {
            _ = try MetalEngine.shared.ciContext.startTask(
                toRender: composed,
                from: targetRect,
                to: dest,
                at: .zero
            )
            cmd.present(drawable)
            cmd.commit()
        } catch {
            cmd.commit()
        }
    }
}
