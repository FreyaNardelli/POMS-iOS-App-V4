import SwiftUI
import SceneKit
import simd

/// Renders the real watch model (`watch3Dmodel.usdz`) with SceneKit and drives
/// its orientation from the live sensor stream:
///  - gyroscope (deg/s) is integrated each frame into the model's rotation, so
///    the on-screen watch turns exactly as the physical watch turns;
///  - accelerometer nudges the model's position slightly along the acceleration
///    direction, so lateral motion is visible too;
///  - with no packets arriving, it idles with a slow auto-spin so you can see it
///    is a live 3D object.
struct WatchModel3DView: UIViewRepresentable {

    /// Increment to snap the model back to its base (face-up) pose. Lets the user
    /// re-align the physical watch to a known reference.
    var resetToken: Int = 0

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.isUserInteractionEnabled = true // edited, changed from false
        view.rendersContinuously = true

        let scene: SCNScene
        if let url = Bundle.main.url(forResource: "watch3Dmodel", withExtension: "usdz"),
           let loaded = try? SCNScene(url: url, options: [.checkConsistency: false]) {
            scene = loaded
        } else {
            scene = SCNScene()   // model missing → empty scene (see README to add it to the target)
        }
        view.scene = scene

        // Re-parent all geometry under pivot > base > content.
        // `base` holds the fixed 270° rotation about Y (the gravity axis) so the
        // watch sits in the user's preferred pose; `pivot` carries the live
        // sensor-driven rotation on top.
        let pivot = SCNNode()
        let base = SCNNode()
        base.eulerAngles = SCNVector3(0, 3 * Float.pi / 2, 0)
        let content = SCNNode()
        for child in scene.rootNode.childNodes where child.camera == nil && child.light == nil {
            child.removeFromParentNode()
            content.addChildNode(child)
        }
        let (minV, maxV) = content.boundingBox
        content.position = SCNVector3(-(minV.x + maxV.x) / 2,
                                      -(minV.y + maxV.y) / 2,
                                      -(minV.z + maxV.z) / 2)
        base.addChildNode(content)
        pivot.addChildNode(base)
        scene.rootNode.addChildNode(pivot)

        // Frame the model with a camera sized to its bounds.
        let extent = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)
        let radius = extent == 0 ? 0.2 : extent
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = Double(radius) * 20
        camera.position = SCNVector3(0, 0, radius * 4.6) // SCNVector3(0, 0, radius * 2.3)
        scene.rootNode.addChildNode(camera)

        // Soft fill so the PBR materials read on the dark panel.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        context.coordinator.pivot = pivot
        context.coordinator.nudge = radius * 0.06
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if resetToken != context.coordinator.lastResetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.reset()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var pivot: SCNNode?
        var nudge: Float = 0.02
        var lastResetToken: Int = 0
        private var link: CADisplayLink?
        private var ex: Double = 0, ey: Double = 0, ez: Double = 0
        private var last: CFTimeInterval = 0

        /// Snap back to the base (face-up) pose by zeroing the integrated rotation.
        func reset() {
            ex = 0; ey = 0; ez = 0
            pivot?.eulerAngles = SCNVector3Zero
            pivot?.position = SCNVector3Zero
        }

        func start() {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let pivot = pivot else { return }
            let now = link.timestamp
            let dt = last == 0 ? 0 : min(now - last, 0.1)
            last = now

            let store = SensorStore.shared
            let sample = store.latest
            let g = sample?.gyro ?? .zero          // rad/s (Android gyroscope)
            let a = sample?.accel ?? SIMD3<Double>(0, 0, 0)
            let live = sample != nil && store.packetsPerSecond > 0
            let rotating = (abs(g.x) + abs(g.y) + abs(g.z)) > 0.12   // rad/s

            if rotating {
                // Gyro is already rad/s — integrate directly into the rotation.
                ex += g.z * dt
                ey -= g.y * dt
                ez += g.x * dt
            } else if !live {
                ey += 0.35 * dt                    // idle auto-spin when no stream
            }
            pivot.eulerAngles = SCNVector3(Float(ex), Float(ey), Float(ez))

            // Acceleration → small positional nudge (clamped to ±1 g range).
            let cx = Float(max(-1, min(1, a.x))) * nudge
            let cy = Float(max(-1, min(1, a.y))) * nudge
            let p = pivot.position
            pivot.position = SCNVector3(p.x + (cx - p.x) * 0.2,
                                        p.y + (cy - p.y) * 0.2,
                                        0)
        }

        deinit { link?.invalidate() }
    }
}
