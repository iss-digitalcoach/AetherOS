import SwiftUI
import MetalKit

/// Uniform block. Layout must match `GlassUniforms` in the shader source (80 bytes).
struct GlassUniforms {
    var resolution: SIMD2<Float> = .zero
    var mouse: SIMD2<Float> = SIMD2(0.5, 0.2)   // 0...1, origin top-left
    var time: Float = 0
    var grain: Float = 0.06
    var specular: Float = 0.8
    var cornerRadius: Float = 22
    var tint: SIMD4<Float> = SIMD4(0.05, 0.06, 0.09, 0.35)
    var glow: SIMD4<Float> = SIMD4(1, 1, 1, 0.35)   // rgb + intensity
    var extra: SIMD4<Float> = SIMD4(1, 0, 0, 0)     // x = isDark
}

/// Metal source is embedded and compiled at runtime so `swift build` works with no
/// offline metallib step. Move it to a .metal file once you ship through Xcode.
enum GlassShaderSource {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct GlassUniforms {
        float2 resolution;
        float2 mouse;
        float  time;
        float  grain;
        float  specular;
        float  cornerRadius;
        float4 tint;
        float4 glow;
        float4 extra;
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut glass_vs(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);          // fullscreen triangle
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 glass_fs(VOut in [[stage_in]], constant GlassUniforms &u [[buffer(0)]]) {
        float dark = u.extra.x;
        float2 px = in.uv * u.resolution;
        float2 c  = px - u.resolution * 0.5;
        float  d  = sdRoundBox(c, u.resolution * 0.5 - 1.0, u.cornerRadius);   // <0 inside
        float  mask = 1.0 - smoothstep(-1.0, 1.0, d);

        float inner = max(-d, 0.0);
        float edge  = exp(-inner / 3.5);                       // hairline inner rim
        float soft  = exp(-inner / 16.0);                      // wider inner bloom

        // Light comes from the top-left: rim is brightest there, dim at bottom-right.
        float2 n = normalize(c + 0.0001);
        float  lit = clamp(0.55 + 0.45 * dot(n, normalize(float2(-0.55, -0.85))), 0.0, 1.0);

        // Cursor-following specular trail, strongest near the rim.
        float2 m = u.mouse * u.resolution;
        float  dist = length(px - m);
        float  spot = exp(-(dist * dist) / (2.0 * 170.0 * 170.0));
        float  rimSpec = edge * (0.35 * lit + spot) * u.specular;

        // Slow orbiting sheen.
        float ang   = atan2(c.y, c.x);
        float sweep = pow(0.5 + 0.5 * sin(ang * 2.0 - u.time * 0.6), 10.0);
        float sheen = soft * sweep * 0.12 * u.specular;

        // Top-of-glass reflection and bottom depth.
        float topGlow = smoothstep(0.55, 0.0, in.uv.y) * 0.10 * u.glow.a * (0.6 + 0.4 * lit);
        float bottomShade = smoothstep(0.55, 1.0, in.uv.y) * (dark > 0.5 ? 0.10 : 0.04);

        // Breathing ambient glow bleeding from the border.
        float breathe = 0.75 + 0.25 * sin(u.time * 0.9);
        float glowAmt = soft * u.glow.a * 0.10 * breathe;

        // Film grain.
        float g = (hash21(px + fract(u.time * 0.5) * 97.0) - 0.5) * u.grain;

        float3 base = u.tint.rgb;
        float3 light3 = u.glow.rgb;
        float3 col = base
                   + light3 * (rimSpec + sheen + topGlow + glowAmt)
                   - float3(bottomShade)
                   + g;
        float a = u.tint.a + rimSpec * 0.5 + sheen + topGlow * 0.6 + abs(g) * 0.4;
        // Light mode: keep a faint dark hairline so the edge reads on white backgrounds.
        if (dark < 0.5) { col -= float3(edge * 0.06); a += edge * 0.05; }
        a = clamp(a, 0.0, 1.0) * mask;
        return float4(clamp(col, 0.0, 1.0) * a, a);             // premultiplied
    }
    """#
}

struct GlassBackground: NSViewRepresentable {
    var theme: Theme
    var isDark: Bool
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // Real backdrop blur comes from the compositor; Metal can't sample other apps'
        // windows without ScreenCaptureKit, so we layer our shader on top of it.
        let container = NSView()
        container.wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = isDark ? .hudWindow : .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = CGFloat(theme.cornerRadius)
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        guard let device = MTLCreateSystemDefaultDevice() else { return container }
        let mtk = MTKView(frame: .zero, device: device)
        mtk.autoresizingMask = [.width, .height]
        mtk.framebufferOnly = true
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtk.layer?.isOpaque = false
        mtk.preferredFramesPerSecond = UserDefaults.standard.bool(forKey: "ecoMode") ? 30 : 60
        mtk.enableSetNeedsDisplay = false
        mtk.isPaused = !isActive
        context.coordinator.configure(view: mtk, device: device)
        mtk.delegate = context.coordinator
        container.addSubview(mtk)

        context.coordinator.blur = blur
        container.subviews.forEach { $0.frame = container.bounds }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.apply(theme: theme, isDark: isDark)
        context.coordinator.blur?.material = isDark ? .hudWindow : .popover
        context.coordinator.blur?.layer?.cornerRadius = CGFloat(theme.cornerRadius)
        if let mtk = nsView.subviews.compactMap({ $0 as? MTKView }).first {
            mtk.isPaused = !isActive
            mtk.preferredFramesPerSecond = UserDefaults.standard.bool(forKey: "ecoMode") ? 30 : 60
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var blur: NSVisualEffectView?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var uniforms = GlassUniforms()
        private let start = CACurrentMediaTime()
        private var smoothedMouse = SIMD2<Float>(0.5, 0.2)

        func configure(view: MTKView, device: MTLDevice) {
            queue = device.makeCommandQueue()
            do {
                let lib = try device.makeLibrary(source: GlassShaderSource.source, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: "glass_vs")
                desc.fragmentFunction = lib.makeFunction(name: "glass_fs")
                let att = desc.colorAttachments[0]!
                att.pixelFormat = view.colorPixelFormat
                att.isBlendingEnabled = true
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("AetherOS glass shader failed: \(error)")
            }
        }

        func apply(theme: Theme, isDark: Bool) {
            let p = theme.palette(dark: isDark)
            let t = p.tintColor.simd
            uniforms.tint = SIMD4(t.x, t.y, t.z, Float(p.tintOpacity))
            let g = p.glowColor.simd
            uniforms.glow = SIMD4(g.x, g.y, g.z, Float(p.glowIntensity))
            uniforms.grain = Float(p.grain)
            uniforms.specular = Float(p.specular)
            uniforms.cornerRadius = Float(theme.cornerRadius)
            uniforms.extra = SIMD4(isDark ? 1 : 0, 0, 0, 0)
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        private func render(in view: MTKView) {
            guard let pipeline, let queue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

            let scale = Float(view.window?.backingScaleFactor ?? 2)
            uniforms.resolution = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
            uniforms.time = Float(CACurrentMediaTime() - start)
            _ = scale

            if let win = view.window {
                let p = view.convert(win.mouseLocationOutsideOfEventStream, from: nil)
                let target = SIMD2(Float(p.x / max(view.bounds.width, 1)),
                                   Float(1 - p.y / max(view.bounds.height, 1)))
                smoothedMouse += (target - smoothedMouse) * 0.18   // easing = "light trail"
                uniforms.mouse = smoothedMouse
            }

            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
