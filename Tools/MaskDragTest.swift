import Foundation

/// 蒙版控制点拖动的回归测试。
///
/// 锁死一个真实 bug：`Handle` 以前上报 `position + v.translation`，而
/// `translation` 是**从按下那一刻算起的累计位移**、`position` 又会随蒙版更新每帧重算，
/// 结果同一个位移被反复叠加 —— 鼠标拖 120px，控制点会跑 240px 甚至上千 px，
/// 三条参考线看上去就是「飘走了」。鼠标事件越密（拖得越顺滑），偏得越离谱。
///
/// 正确写法：以「按下点 + 按下那一刻的蒙版」为基准，用绝对坐标算增量。
@main
struct MaskDragTest {
    static var failures = 0

    static func check(_ passed: Bool, _ message: String) {
        if passed {
            print("PASS: \(message)")
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func linearMask() -> Mask {
        var m = Mask()
        m.kind = .linear
        m.gradientVersion = 1
        m.x0 = 0.2; m.y0 = 0.5
        m.x1 = 0.8; m.y1 = 0.5
        return m
    }

    /// 控制点在叠加层里的位置（y 向下），与 MaskOverlay.linearGuides 一致
    static func handle(_ m: Mask, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * m.x0, y: size.height * (1 - m.y0))
    }

    /// 模拟一次拖动：events 是每一步的**累计**位移（DragGesture 的 translation 语义）。
    /// 走的是 MaskOverlay 同一套流程 —— 按下时建会话，之后每次移动都用绝对坐标算。
    static func drag(_ base: Mask, control: MaskGeometry.Control, grab: CGPoint,
                     events: [Double], size: CGSize, dx: Double, dy: Double = 0) -> Mask {
        let session = MaskDragSession(start: grab, base: base)
        var out = base
        for t in events {
            let end = CGPoint(x: grab.x + dx * t, y: grab.y + dy * t)
            out = session.updated(control, to: end, size: size)
        }
        return out
    }

    static func main() {
        let size = CGSize(width: 800, height: 600)
        let base = linearMask()
        let p0 = handle(base, size)                       // (160, 300)
        let p1 = CGPoint(x: size.width * base.x1, y: size.height * (1 - base.y1))
        let c = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)

        // 粗粒度（5 个事件）与细粒度（61 / 1200 个事件）必须给出同一结果。
        // 这就是那个 bug 的判据：累计位移被反复叠加时，事件越密结果偏得越远。
        let coarse: [Double] = [10, 20, 30, 60, 120]
        let fine: [Double] = stride(from: 2.0, through: 120.0, by: 2.0).map { $0 }
        let ultraFine: [Double] = stride(from: 0.1, through: 120.0, by: 0.1).map { $0 }
        let want = 120.0 / Double(size.width)

        let a = drag(base, control: .linearStart, grab: p0, events: coarse, size: size, dx: 1)
        check(abs(a.x0 - (base.x0 + want)) < 1e-9,
              String(format: "起点控制点右拖 120px（5 次事件）位移正确：x0 %.5f → %.5f", base.x0, a.x0))

        let b = drag(base, control: .linearStart, grab: p0, events: fine, size: size, dx: 1)
        let c2 = drag(base, control: .linearStart, grab: p0, events: ultraFine, size: size, dx: 1)
        check(abs(b.x0 - a.x0) < 1e-9 && abs(c2.x0 - a.x0) < 1e-9,
              String(format: "结果不随鼠标事件数漂移（5 / 61 / 1200 次事件）：%.5f", c2.x0))

        // 终点控制点
        let e = drag(base, control: .linearEnd, grab: p1, events: fine, size: size, dx: -1)
        check(abs(e.x1 - (base.x1 - want)) < 1e-9,
              String(format: "终点控制点左拖 120px：x1 %.5f → %.5f", base.x1, e.x1))

        // 整体平移：两端位移相同
        let mv = drag(base, control: .move, grab: c, events: fine, size: size, dx: 1)
        check(abs((mv.x1 - mv.x0) - (base.x1 - base.x0)) < 1e-9 && abs(mv.x0 - (base.x0 + want)) < 1e-9,
              String(format: "整体平移 120px 后两条端点间距不变：x0 %.5f x1 %.5f", mv.x0, mv.x1))

        // 旋转柄：绕中心转 90°（初始抓取角 -90°，终点角 0°）
        let rotateGrab = CGPoint(x: c.x, y: c.y + 26)
        let rotateEnd = CGPoint(x: c.x + 26, y: c.y)
        let rot = MaskGeometry.dragging(base, control: .rotate, from: rotateGrab, to: rotateEnd, size: size)
        let rotAngle = MaskGeometry.angle(rot, size: size)
        check(abs(rotAngle - 90) < 0.5,
              String(format: "线性旋转柄拖 90° 后角度正确：%.1f°", rotAngle))

        // 径向旋转柄使用画布坐标（Y 向下），而 radialAngle 使用图像坐标（Y 向上）。
        // 画布里从右向上拖动时，内部角度应为 -90°，这样渲染出来的椭圆也向上转。
        var radialRotation = Mask()
        radialRotation.kind = .radial
        radialRotation.gradientVersion = 1
        radialRotation.x0 = 0.5; radialRotation.y0 = 0.5
        radialRotation.radiusX = 0.2; radialRotation.radiusY = 0.12
        radialRotation.radialAngle = 0
        let radialCenter = CGPoint(x: size.width * radialRotation.x0,
                                   y: size.height * (1 - radialRotation.y0))
        let radialRotateGrab = CGPoint(x: radialCenter.x + 26, y: radialCenter.y)
        let radialRotateEnd = CGPoint(x: radialCenter.x, y: radialCenter.y - 26)
        let radialRotated = MaskGeometry.dragging(radialRotation, control: .rotate,
                                                   from: radialRotateGrab, to: radialRotateEnd,
                                                   size: size)
        let radialAngle = MaskGeometry.angle(radialRotated, size: size)
        check(abs(radialAngle + 90) < 0.5,
              String(format: "径向旋转柄向左上拖 90° 方向正确：%.1f°", radialAngle))

        // 径向：拖到距圆心 240px 处，radiusX 应为 240 / min(800,600)
        var radial = Mask()
        radial.kind = .radial
        radial.gradientVersion = 1
        radial.x0 = 0.5; radial.y0 = 0.5
        radial.radiusX = 0.2; radial.radiusY = 0.2
        radial.radialAngle = 0
        let rc = CGPoint(x: size.width * radial.x0, y: size.height * (1 - radial.y0))
        let rx = drag(radial, control: .radialX, grab: rc, events: fine, size: size, dx: 1, dy: 0)
        // 终点 = rc.x + 120，距圆心 120px
        check(abs((rx.radiusX ?? 0) - 120.0 / 600.0) < 1e-9,
              String(format: "径向 X 手柄拖到 120px 处：radiusX = %.4f", rx.radiusX ?? -1))

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
