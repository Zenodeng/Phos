import Foundation
import simd

/// Metal Compute Shaders 源码与 Uniform 结构定义（全部运行于 RGBA16Float 线性浮点空间）。
enum MetalShaders {
    struct ContrastAgXUniforms {
        var contrast: Float
        var pivotOffset: Float
        var rolloff: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct GuidedFilterPackUniforms {
        var scaleX: Float
        var scaleY: Float
        var inOriginX: Int32
        var inOriginY: Int32
        var selfGuided: Int32
    }

    struct BoxPassUniforms {
        var radius: Int32
    }

    struct GuidedCoeffUniforms {
        var eps: Float
    }

    struct LocalToneUniforms {
        var highlights: Float
        var shadows: Float
        var whites: Float
        var blacks: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct DehazeUniforms {
        var amount: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct EdgeDetailUniforms {
        var clarity: Float
        var texture: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct CurvesGradingUniforms {
        var toneActive: Int32
        var lumaActive: Int32
        var rgbCurveActive: Int32
        var refineSat: Float
        var shadowRGB: SIMD4<Float>   // rgb + sat
        var midRGB: SIMD4<Float>
        var highRGB: SIMD4<Float>
        var shadowLum: Float
        var midLum: Float
        var highLum: Float
        var blendK: Float
        var balance: Float
        var shadowTint: Float
        var gradingActive: Int32
        var offsetX: Int32
        var offsetY: Int32
    }

    struct PointColorUniform {
        var targetLCH: SIMD4<Float>   // (L, C, h_rad, active)
        var shiftLCH: SIMD4<Float>    // (dl, dc, dh_rad, 0)
        var rangeLCH: SIMD4<Float>    // (rL, rC, rH, overall)
    }

    struct OKLCHColorUniforms {
        var bandHue: SIMD4<Float>     // 0..3
        var bandHue2: SIMD4<Float>    // 4..7
        var bandSat: SIMD4<Float>
        var bandSat2: SIMD4<Float>
        var bandLum: SIMD4<Float>
        var bandLum2: SIMD4<Float>
        var hslActive: Int32
        var pointCount: Int32
        var localHueShift: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct FilmGrainUniforms {
        var amount: Float
        var size: Float
        var roughness: Float
        var aspect: Float
        var fullWidth: Float
        var fullHeight: Float
        var outOriginX: Int32
        var outOriginY: Int32
        var offsetX: Int32
        var offsetY: Int32
    }

    struct BoolMaskUniforms {
        var mode: Int32               // 0=add, 1=subtract, 2=intersect
        var offsetX: Int32
        var offsetY: Int32
        var subOffsetX: Int32
        var subOffsetY: Int32
    }

    struct OpticalBokehUniforms {
        var maxRadiusPx: Float
        var focusDepth: Float
        var focusRange: Float
        var blades: Int32
        var highlightBoost: Float
        var catEye: Float
        var fullWidth: Float
        var fullHeight: Float
        var outOriginX: Float
        var outOriginY: Float
        var offsetX: Int32
        var offsetY: Int32
        var depthOffsetX: Int32
        var depthOffsetY: Int32
    }

    struct DepthVisUniforms {
        var focusDepth: Float
        var focusRange: Float
        var offsetX: Int32
        var offsetY: Int32
        var depthOffsetX: Int32
        var depthOffsetY: Int32
    }

    struct RawDenoiseUniforms {
        var amount: Float
        var detail: Float
        var lumaSigma: Float
        var chromaSigma: Float
        var chromaOnly: Int32
        var stepPx: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    struct SuperResUniforms {
        var sharpen: Float
        var edgePreserve: Float
        var offsetX: Int32
        var offsetY: Int32
    }

    static let source = #"""
#include <metal_stdlib>
using namespace metal;

constant float3 LUMA_W = float3(0.2126, 0.7152, 0.0722);

inline float3 toPerceptual(float3 v) {
    float3 a = max(v, 0.0);
    float3 low = a * 12.92;
    float3 high = 1.055 * pow(a, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, a <= 0.0031308);
}

inline float toPerceptual1(float v) {
    float a = max(v, 0.0);
    return a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
}

inline float3 toLinear(float3 v) {
    float3 a = max(v, 0.0);
    float3 low = a / 12.92;
    float3 high = pow((a + 0.055) / 1.055, float3(2.4));
    return select(high, low, a <= 0.04045);
}

inline float toLinear1(float v) {
    float a = max(v, 0.0);
    return a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
}

inline float4 readClamped(texture2d<float, access::read> tex, int2 coord) {
    int2 maxC = int2(tex.get_width() - 1, tex.get_height() - 1);
    return tex.read(uint2(clamp(coord, int2(0), maxC)));
}

// MARK: - 1. 对数中灰对比度 + AgX 高光滚降
struct ContrastAgXUniforms {
    float contrast;
    float pivotOffset;
    float rolloff;
    int offsetX;
    int offsetY;
};

inline float curveLogVal(float v, float pivot, float slope, float shoulder) {
    float x = log2(max(v, 1e-5) / pivot);
    float s = x * slope / (1.0 + abs(x) * shoulder);
    return pivot * exp2(clamp(s, -12.0, 12.0));
}

kernel void contrast_agx(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant ContrastAgXUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = px.rgb;

    if (abs(u.contrast) > 1e-4) {
        float pivot = 0.18 * exp2(u.pivotOffset);
        float slope = u.contrast >= 0.0 ? (1.0 + u.contrast * 0.85) : (1.0 / (1.0 - u.contrast * 0.72));
        float shoulder = u.contrast >= 0.0 ? (u.contrast * 0.28) : 0.0;

        float y0 = max(dot(rgb, LUMA_W), 1e-5);
        float y1 = curveLogVal(y0, pivot, slope, shoulder);
        float lumaScale = y1 / y0;
        float3 byLuma = rgb * lumaScale;
        float3 byChannel = float3(
            rgb.r < 0.0 ? rgb.r * lumaScale : curveLogVal(rgb.r, pivot, slope, shoulder),
            rgb.g < 0.0 ? rgb.g * lumaScale : curveLogVal(rgb.g, pivot, slope, shoulder),
            rgb.b < 0.0 ? rgb.b * lumaScale : curveLogVal(rgb.b, pivot, slope, shoulder)
        );
        // 正对比保护肤色/色度，不过冲；负对比按通道平缓收柔
        float chanMix = u.contrast >= 0.0 ? 0.28 : 0.45;
        rgb = mix(byLuma, byChannel, chanMix);
    }

    if (u.rolloff > 1e-4) {
        float r = u.rolloff;
        float mx = max(rgb.r, max(rgb.g, rgb.b));
        float knee = 0.65 - r * 0.25;
        if (mx > knee) {
            float excess = mx - knee;
            float headroom = max(1.0 - knee, 0.12) * (1.0 + 0.35 * (1.0 - r));
            float compressed = knee + excess * headroom / max(headroom + excess * (0.75 + r * 0.45), 1e-5);
            float scale = compressed / max(mx, 1e-5);
            // AgX 风格高光自然退饱和：极高光随溢出向中性光收敛
            float desat = clamp(excess / (excess + 0.85) * r * 0.45, 0.0, 0.55);
            float avg = (rgb.r + rgb.g + rgb.b) / 3.0;
            rgb = mix(rgb, float3(avg), desat) * scale;
        }
    }

    dst.write(float4(rgb, px.a), gid);
}

// MARK: - 2. Fast Guided Filter 子 Pass
struct GuidedFilterPackUniforms {
    float scaleX;
    float scaleY;
    int inOriginX;
    int inOriginY;
    int selfGuided;
};

struct BoxPassUniforms {
    int radius;
};

struct GuidedCoeffUniforms {
    float eps;
};

kernel void gf_pack(
    texture2d<float, access::sample> guideTex [[texture(0)]],
    texture2d<float, access::sample> targetTex [[texture(1)]],
    texture2d<float, access::write> outPack [[texture(2)]],
    constant GuidedFilterPackUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outPack.get_width() || gid.y >= outPack.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(outPack.get_width(), outPack.get_height());
    float4 g4 = guideTex.sample(s, uv);
    float I = clamp(toPerceptual1(max(dot(g4.rgb, LUMA_W), 0.0)), 0.0, 1.5);
    float p = I;
    if (u.selfGuided == 0) {
        p = clamp(targetTex.sample(s, uv).r, 0.0, 1.5);
    }
    outPack.write(float4(I, p, I * I, I * p), gid);
}

kernel void gf_pack_logluma(
    texture2d<float, access::sample> guideTex [[texture(0)]],
    texture2d<float, access::write> outPack [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outPack.get_width() || gid.y >= outPack.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(outPack.get_width(), outPack.get_height());
    float3 rgb = max(guideTex.sample(s, uv).rgb, float3(0.0));
    float y = max(dot(rgb, LUMA_W), 1e-4);
    float L = clamp((log2(y) + 10.0) / 14.0, 0.0, 1.5);
    outPack.write(float4(L, L, L * L, L * L), gid);
}

kernel void gf_pack_darkchannel(
    texture2d<float, access::sample> guideTex [[texture(0)]],
    texture2d<float, access::write> outPack [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outPack.get_width() || gid.y >= outPack.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(outPack.get_width(), outPack.get_height());
    float2 texel = 1.0 / float2(outPack.get_width(), outPack.get_height());
    float dark = 1.0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float3 c = toPerceptual(clamp(guideTex.sample(s, uv + float2(dx, dy) * texel).rgb, 0.0, 1.0));
            dark = min(dark, min(c.r, min(c.g, c.b)));
        }
    }
    float3 c0 = toPerceptual(clamp(guideTex.sample(s, uv).rgb, 0.0, 1.0));
    float I = dot(c0, LUMA_W);
    outPack.write(float4(I, dark, I * I, I * dark), gid);
}

kernel void gf_box_h(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BoxPassUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int r = max(1, u.radius);
    float4 acc = float4(0.0);
    int y = int(gid.y);
    for (int dx = -r; dx <= r; ++dx) {
        int x = clamp(int(gid.x) + dx, 0, w - 1);
        acc += src.read(uint2(x, y));
    }
    dst.write(acc / float(2 * r + 1), gid);
}

kernel void gf_box_v(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant BoxPassUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int r = max(1, u.radius);
    float4 acc = float4(0.0);
    int x = int(gid.x);
    for (int dy = -r; dy <= r; ++dy) {
        int y = clamp(int(gid.y) + dy, 0, h - 1);
        acc += src.read(uint2(x, y));
    }
    dst.write(acc / float(2 * r + 1), gid);
}

kernel void gf_coeff(
    texture2d<float, access::read> meanTex [[texture(0)]],
    texture2d<float, access::write> coeffTex [[texture(1)]],
    constant GuidedCoeffUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= coeffTex.get_width() || gid.y >= coeffTex.get_height()) return;
    float4 m = meanTex.read(gid);
    float meanI = m.x, meanP = m.y, corrII = m.z, corrIp = m.w;
    float varI = max(corrII - meanI * meanI, 0.0);
    float covIp = corrIp - meanI * meanP;
    float a = covIp / (varI + u.eps);
    float b = meanP - a * meanI;
    coeffTex.write(float4(a, b, 0.0, 1.0), gid);
}

kernel void gf_apply_mask(
    texture2d<float, access::read> guideFull [[texture(0)]],
    texture2d<float, access::sample> meanCoeff [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant int2 &offset [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(int2(gid) + offset) + 0.5) / float2(guideFull.get_width(), guideFull.get_height());
    float4 ab = meanCoeff.sample(s, uv);
    float4 g4 = readClamped(guideFull, int2(gid) + offset);
    float I = clamp(toPerceptual1(max(dot(g4.rgb, LUMA_W), 0.0)), 0.0, 1.5);
    float q = clamp(ab.x * I + ab.y, 0.0, 1.0);
    dst.write(float4(q, q, q, 1.0), gid);
}

// MARK: - 3. 保边局部影调 (Highlights / Shadows + 双向 Whites / Blacks)
struct LocalToneUniforms {
    float highlights;
    float shadows;
    float whites;
    float blacks;
    int offsetX;
    int offsetY;
};

kernel void local_tone_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::sample> meanCoeff [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant LocalToneUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = px.rgb;
    float y = dot(rgb, LUMA_W);

    if ((abs(u.highlights) > 1e-4 || abs(u.shadows) > 1e-4) && y > 1e-5) {
        float2 uv = (float2(int2(gid) + int2(u.offsetX, u.offsetY)) + 0.5) / float2(src.get_width(), src.get_height());
        float4 ab = meanCoeff.sample(s, uv);
        float L = clamp((log2(max(y, 1e-4)) + 10.0) / 14.0, 0.0, 1.5);
        float baseL = ab.x * L + ab.y;
        float detailL = L - baseL;

        // 将归一化对数亮度转为感知亮度估值（sRGB 大致 0..1+）
        float baseLin = exp2(baseL * 14.0 - 10.0);
        float basePerc = toPerceptual1(baseLin);

        float delta = 0.0;
        if (abs(u.highlights) > 1e-4) {
            float hw = smoothstep(0.38, 0.92, basePerc);
            if (u.highlights < 0.0) {
                // 在 14 档 log2 空间里恢复：SDR 下压约 1.4 档 (-0.10)，对 >1.0 线性高光渐进加压而不截死层次
                float extra = min(max(log2(max(baseLin, 1.0)) * 0.35, 0.0), 1.5) / 14.0;
                delta += u.highlights * (0.10 + extra) * hw;
            } else {
                delta += u.highlights * 0.085 * hw;
            }
        }
        if (abs(u.shadows) > 1e-4) {
            float sw = 1.0 - smoothstep(0.08, 0.58, basePerc);
            delta += u.shadows * 0.13 * sw;
        }

        // 在保持细节层的同时调整低频层（轻微保护极高对比细节不过冲）
        float newBaseL = baseL + delta;
        float detailKeep = 1.0 + (u.highlights < 0.0 ? 0.08 * (-u.highlights) * smoothstep(0.5, 1.0, basePerc) : 0.0);
        float newL = newBaseL + detailL * detailKeep;
        float newY = exp2(clamp(newL * 14.0 - 10.0, -13.5, 4.5));
        float gain = clamp(newY / y, 0.05, 12.0);
        rgb *= gain;
    }

    // 双向 Whites / Blacks 精细处理（保留渐变与广色域负值坐标，不死切）
    if (abs(u.whites) > 1e-4 || abs(u.blacks) > 1e-4) {
        float y2 = max(dot(rgb, LUMA_W), 0.0);
        float pY = toPerceptual1(y2);
        float gain = 1.0;
        if (abs(u.whites) > 1e-4) {
            float ww = smoothstep(0.45, 0.98, pY);
            gain *= max(1.0 + u.whites * 0.42 * ww, 0.15);
        }
        rgb *= gain;

        if (abs(u.blacks) > 1e-4) {
            float3 safeRGB = max(rgb, float3(0.0));
            float3 perc = toPerceptual(safeRGB);
            float3 percOrig = perc;
            if (u.blacks > 0.0) {
                float lift = u.blacks * 0.095;
                float3 w = 1.0 - smoothstep(float3(0.0), float3(0.45), perc);
                perc = perc + lift * w;
            } else {
                float crush = -u.blacks * 0.11;
                float3 w = 1.0 - smoothstep(float3(0.0), float3(0.38), perc);
                perc = max(perc - crush * w, float3(0.0));
            }
            float3 deltaLin = toLinear(min(perc, float3(1.0))) - toLinear(min(percOrig, float3(1.0)));
            rgb += select(float3(0.0), deltaLin, rgb <= 1.0 && rgb >= -0.0001);
        }
    }

    dst.write(float4(rgb, px.a), gid);
}

// MARK: - 4. 暗通道去朦胧
struct DehazeUniforms {
    float amount;
    int offsetX;
    int offsetY;
};

kernel void dehaze_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::sample> meanCoeff [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant DehazeUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = max(px.rgb, float3(0.0));
    float2 uv = (float2(int2(gid) + int2(u.offsetX, u.offsetY)) + 0.5) / float2(src.get_width(), src.get_height());
    float4 ab = meanCoeff.sample(s, uv);
    float3 perc = toPerceptual(min(rgb, float3(1.0)));
    float I = dot(perc, LUMA_W);
    float dark = clamp(ab.x * I + ab.y, 0.0, 0.95);

    if (u.amount > 0.0) {
        float omega = min(u.amount * 0.65, 0.72);
        float t = clamp(1.0 - omega * dark, 0.25, 1.0);
        float3 A = float3(0.95);
        float3 rec = (perc - A) / t + A;
        // 轻微抗死黑保护与自然饱和收敛
        rec = max(rec, perc * 0.12);
        float3 linLow = toLinear(clamp(rec, 0.0, 1.0));
        rgb = select(rgb, linLow, rgb <= 1.0);
    } else {
        float fog = clamp((-u.amount) * 0.42 * (0.4 + 0.6 * (1.0 - dark)), 0.0, 0.65);
        float3 hazed = mix(perc, float3(0.86), fog);
        float3 linLow = toLinear(clamp(hazed, 0.0, 1.0));
        rgb = select(rgb, linLow, rgb <= 1.0);
    }
    dst.write(float4(max(rgb, float3(0.0)), px.a), gid);
}

// MARK: - 5. 保边清晰度与纹理
struct EdgeDetailUniforms {
    float clarity;
    float texture;
    int offsetX;
    int offsetY;
};

kernel void edge_detail_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::sample> clarityCoeff [[texture(1)]],
    texture2d<float, access::sample> textureCoeff [[texture(2)]],
    texture2d<float, access::write> dst [[texture(3)]],
    constant EdgeDetailUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = px.rgb;
    float y = dot(rgb, LUMA_W);
    if (y > 1e-5) {
        float2 uv = (float2(int2(gid) + int2(u.offsetX, u.offsetY)) + 0.5) / float2(src.get_width(), src.get_height());
        float pY = toPerceptual1(y);
        float detail = 0.0;
        if (abs(u.clarity) > 1e-4) {
            float4 ab = clarityCoeff.sample(s, uv);
            float baseC = ab.x * min(pY, 1.5) + ab.y;
            float dC = pY - baseC;
            // 防白边软限幅
            detail += tanh(dC * 3.0) / 3.0 * u.clarity * 0.95;
        }
        if (abs(u.texture) > 1e-4) {
            float4 ab = textureCoeff.sample(s, uv);
            float baseT = ab.x * min(pY, 1.5) + ab.y;
            float dT = pY - baseT;
            detail += tanh(dT * 4.0) / 4.0 * u.texture * 0.85;
        }
        float pOut = max(pY + detail, 0.0);
        float yOut = toLinear1(pOut);
        rgb *= clamp(yOut / y, 0.25, 4.0);
    }
    dst.write(float4(rgb, px.a), gid);
}

// MARK: - 6. 5 通道浮点曲线 + Refine Sat + 颜色分级
struct CurvesGradingUniforms {
    int toneActive;
    int lumaActive;
    int rgbCurveActive;
    float refineSat;
    float4 shadowRGB;
    float4 midRGB;
    float4 highRGB;
    float shadowLum;
    float midLum;
    float highLum;
    float blendK;
    float balance;
    float shadowTint;
    int gradingActive;
    int offsetX;
    int offsetY;
};

inline float sampleCurveLUT(constant float *lut, float x) {
    if (x <= 0.0) return lut[0];
    if (x >= 1.0) {
        // 对 HDR > 1.0 高光采用末端斜率外推，绝不硬削平
        float slope = clamp((lut[255] - lut[247]) / (8.0 / 255.0), 0.1, 2.0);
        return lut[255] + (x - 1.0) * slope;
    }
    float idx = x * 255.0;
    int i0 = clamp(int(idx), 0, 254);
    float f = idx - float(i0);
    return mix(lut[i0], lut[i0 + 1], f);
}

inline float3 gradeDeltaVec(float4 col, float w, float blendK) {
    if (col.w <= 0.0) return float3(0.0);
    float k = w * col.w * 0.42 * blendK;
    float3 d = (col.rgb - 0.5) * k;
    float ly = dot(d, LUMA_W);
    return d - float3(ly);
}

kernel void curves_grading_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant CurvesGradingUniforms &u [[buffer(0)]],
    constant float *luts [[buffer(1)]], // 5 * 256: [T, L, R, G, B]
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = max(px.rgb, float3(0.0));
    float3 p0 = toPerceptual(rgb);
    float3 p = p0;

    if (u.toneActive != 0) {
        constant float *lutT = luts;
        p = float3(sampleCurveLUT(lutT, p.r), sampleCurveLUT(lutT, p.g), sampleCurveLUT(lutT, p.b));
    }
    if (u.rgbCurveActive != 0) {
        constant float *lutR = luts + 512;
        constant float *lutG = luts + 768;
        constant float *lutB = luts + 1024;
        p = float3(sampleCurveLUT(lutR, p.r), sampleCurveLUT(lutG, p.g), sampleCurveLUT(lutB, p.b));
    }

    float3 lin = toLinear(max(p, float3(0.0)));
    if (u.lumaActive != 0) {
        constant float *lutL = luts + 256;
        float y = dot(lin, LUMA_W);
        float py = toPerceptual1(y);
        float targetY = toLinear1(max(sampleCurveLUT(lutL, py), 0.0));
        if (y > 0.0005) {
            lin *= targetY / y;
        } else {
            lin = float3(targetY);
        }
        p = toPerceptual(lin);
    }

    if (u.refineSat > 0.001) {
        float y0 = dot(p0, LUMA_W);
        float y1 = dot(p, LUMA_W);
        float k = (y1 + 0.05) / (max(y0, 0.001) + 0.05);
        float3 keep = float3(y1) + (p0 - float3(y0)) * k;
        p = max(mix(p, keep, clamp(u.refineSat, 0.0, 1.0)), float3(0.0));
    }

    if (u.gradingActive != 0) {
        float y = clamp(dot(p, LUMA_W), 0.0, 1.0);
        float b1 = 0.33 + u.balance, b2 = 0.67 + u.balance;
        float wS = 1.0 - clamp((y - (b1 - 0.16)) / 0.32, 0.0, 1.0);
        float wH = clamp((y - (b2 - 0.16)) / 0.32, 0.0, 1.0);
        float wM = 1.0 - min(abs(y - 0.5) / 0.34, 1.0);

        float3 d = gradeDeltaVec(u.shadowRGB, wS, u.blendK)
            + gradeDeltaVec(u.midRGB, wM, u.blendK)
            + gradeDeltaVec(u.highRGB, wH, u.blendK);
        float dl = (u.shadowLum * wS + u.midLum * wM + u.highLum * wH) * 0.28;
        d += float3(dl);

        if (abs(u.shadowTint) > 1e-4) {
            float t = u.shadowTint * 0.35 * wS;
            if (t > 0.0) d.g += t;
            else { d.r += -t * 0.7; d.b += -t * 0.7; }
        }
        p = max(p + d, float3(0.0));
    }

    float3 outLin = toLinear(p);
    dst.write(float4(max(outLin, float3(0.0)), px.a), gid);
}

// MARK: - 7. OKLCH 感知均匀色彩空间 (HSL + Point Color)
struct PointColorUniform {
    float4 targetLCH; // (L, C, h_rad, active)
    float4 shiftLCH;  // (dl, dc, dh_rad, 0)
    float4 rangeLCH;  // (rL, rC, rH, overall)
};

struct OKLCHColorUniforms {
    float4 bandHue;
    float4 bandHue2;
    float4 bandSat;
    float4 bandSat2;
    float4 bandLum;
    float4 bandLum2;
    int hslActive;
    int pointCount;
    float localHueShift;
    int offsetX;
    int offsetY;
};

inline float3 linearSRGBToOKLab(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = pow(max(l, 0.0f), 1.0f / 3.0f);
    float m_ = pow(max(m, 0.0f), 1.0f / 3.0f);
    float s_ = pow(max(s, 0.0f), 1.0f / 3.0f);
    return float3(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    );
}

inline float3 okLabToLinearSRGB(float3 lab) {
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;
    return float3(
        +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );
}

inline float wrapAngleDiff(float a, float b) {
    float d = a - b;
    while (d > M_PI_F) d -= 2.0 * M_PI_F;
    while (d < -M_PI_F) d += 2.0 * M_PI_F;
    return d;
}

kernel void oklch_color_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant OKLCHColorUniforms &u [[buffer(0)]],
    constant PointColorUniform *points [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = px.rgb;
    float peak = max(1.0, max(rgb.r, max(rgb.g, rgb.b)));
    float3 normRGB = rgb / peak;

    float3 lab = linearSRGBToOKLab(normRGB);
    float L = lab.x;
    float C = length(float2(lab.y, lab.z));
    float h = atan2(lab.z, lab.y); // -pi..pi

    if (u.hslActive != 0 && C > 0.008) {
        // OKLCH 中 8 色相中心角（度：红29, 橙58, 黄102, 绿142, 青195, 蓝258, 紫305, 洋红345）
        const float centersDeg[8] = { 29.0, 58.0, 102.0, 142.0, 195.0, 258.0, 305.0, 345.0 };
        float hues[8] = { u.bandHue.x, u.bandHue.y, u.bandHue.z, u.bandHue.w, u.bandHue2.x, u.bandHue2.y, u.bandHue2.z, u.bandHue2.w };
        float sats[8] = { u.bandSat.x, u.bandSat.y, u.bandSat.z, u.bandSat.w, u.bandSat2.x, u.bandSat2.y, u.bandSat2.z, u.bandSat2.w };
        float lums[8] = { u.bandLum.x, u.bandLum.y, u.bandLum.z, u.bandLum.w, u.bandLum2.x, u.bandLum2.y, u.bandLum2.z, u.bandLum2.w };

        float hDeg = h * 180.0 / M_PI_F;
        if (hDeg < 0.0) hDeg += 360.0;
        float wSum = 0.0, dH = 0.0, dS = 0.0, dL = 0.0;
        for (int i = 0; i < 8; ++i) {
            float d = abs(hDeg - centersDeg[i]);
            if (d > 180.0) d = 360.0 - d;
            float w = max(0.0, 1.0 - d / 46.0);
            w = w * w * (3.0 - 2.0 * w);
            if (w > 0.0) {
                wSum += w;
                dH += hues[i] * w;
                dS += sats[i] * w;
                dL += lums[i] * w;
            }
        }
        if (wSum > 0.0) {
            float satMask = smoothstep(0.008, 0.04, C);
            h += (dH / wSum) * (M_PI_F / 180.0) * satMask;
            C = max(0.0, C * (1.0 + (dS / wSum) * 0.9));
            L = clamp(L + (dL / wSum) * 0.22 * satMask, 0.0, 1.0);
        }
    }

    if (abs(u.localHueShift) > 1e-4 && C > 0.004) {
        h += u.localHueShift * (M_PI_F / 180.0);
    }

    for (int i = 0; i < u.pointCount; ++i) {
        PointColorUniform pt = points[i];
        if (pt.targetLCH.w < 0.5) continue;
        float tL = pt.targetLCH.x, tC = pt.targetLCH.y, tH = pt.targetLCH.z;
        float dh = abs(wrapAngleDiff(h, tH)) / max(pt.rangeLCH.z * pt.rangeLCH.w * M_PI_F * 0.55, 0.05);
        float dc = abs(C - tC) / max(pt.rangeLCH.y * pt.rangeLCH.w * 0.18, 0.015);
        float dl = abs(L - tL) / max(pt.rangeLCH.x * pt.rangeLCH.w * 0.45, 0.05);
        float chromaGate = smoothstep(0.005, 0.03, C);
        float w = exp(-0.5 * (dh * dh + dc * dc * 0.65 + dl * dl * 0.45)) * chromaGate;
        if (w > 0.001) {
            h += pt.shiftLCH.z * w;
            C = max(0.0, C * (1.0 + pt.shiftLCH.y * w));
            L = clamp(L + pt.shiftLCH.x * 0.28 * w, 0.0, 1.0);
        }
    }

    float3 outLab = float3(L, C * cos(h), C * sin(h));
    float3 outRGB = okLabToLinearSRGB(outLab) * peak;
    dst.write(float4(outRGB, px.a), gid);
}

// MARK: - 8. 分辨率无关物理银盐颗粒
struct FilmGrainUniforms {
    float amount;
    float size;
    float roughness;
    float aspect;
    float fullWidth;
    float fullHeight;
    int outOriginX;
    int outOriginY;
    int offsetX;
    int offsetY;
};

inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

kernel void film_grain_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant FilmGrainUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float3 rgb = max(px.rgb, float3(0.0));
    float3 perc = toPerceptual(min(rgb, float3(1.0)));

    // 归一化画幅坐标：确保任意代理尺度与原图导出颗粒质感一致
    float2 uv = float2(float(int(gid.x) + u.outOriginX) / max(u.fullWidth, 1.0),
                       float(int(gid.y) + u.outOriginY) / max(u.fullHeight, 1.0));
    uv.x *= u.aspect;
    float freq = mix(1150.0, 260.0, clamp(u.size, 0.0, 1.0));
    float n1 = valueNoise(uv * freq) - 0.5;
    float n2 = valueNoise(uv * freq * 2.07 + 17.3) - 0.5;
    float n3 = valueNoise(uv * freq * 0.51 + 41.7) - 0.5;
    float rough = clamp(u.roughness, 0.0, 1.0);
    float g = n1 * (0.65 - 0.2 * rough) + n2 * (0.35 - 0.1 * rough) + n3 * (0.35 * rough);

    // 银盐密度包络：中灰最强，死黑与纯白减弱
    float y = clamp(dot(perc, LUMA_W), 0.0, 1.0);
    float envelope = sin(clamp(y, 0.0, 1.0) * M_PI_F);
    envelope = mix(0.25, 1.0, envelope);
    float delta = g * u.amount * 0.28 * envelope;
    float3 outPerc = clamp(perc + float3(delta), 0.0, 1.0);
    float3 outLin = toLinear(outPerc);
    rgb = select(rgb, outLin, rgb <= 1.0);
    dst.write(float4(max(rgb, float3(0.0)), px.a), gid);
}

// MARK: - 9. 蒙版布尔合成 & 溢出斑马纹提示
struct BoolMaskUniforms {
    int mode; // 0=add, 1=subtract, 2=intersect
    int offsetX;
    int offsetY;
    int subOffsetX;
    int subOffsetY;
};

kernel void mask_boolean_combine(
    texture2d<float, access::read> baseTex [[texture(0)]],
    texture2d<float, access::read> subTex [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant BoolMaskUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float b = readClamped(baseTex, int2(gid) + int2(u.offsetX, u.offsetY)).r;
    float s = readClamped(subTex, int2(gid) + int2(u.subOffsetX, u.subOffsetY)).r;
    float outV = b;
    if (u.mode == 0) outV = clamp(b + s, 0.0, 1.0);
    else if (u.mode == 1) outV = clamp(b - s, 0.0, 1.0);
    else outV = clamp(b * s, 0.0, 1.0);
    dst.write(float4(outV, outV, outV, 1.0), gid);
}

kernel void clipping_overlay(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant int2 &offset [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + offset);
    float mx = max(px.r, max(px.g, px.b));
    float mn = min(px.r, min(px.g, px.b));
    bool stripe = ((gid.x + gid.y) % 8) < 4;
    if (mx >= 0.996) {
        px.rgb = stripe ? float3(1.0, 0.14, 0.12) : px.rgb * 0.72 + float3(0.28, 0.04, 0.04);
    } else if (mx <= 0.004 && mn <= 0.002) {
        px.rgb = stripe ? float3(0.14, 0.45, 1.0) : px.rgb + float3(0.05, 0.15, 0.42);
    }
    dst.write(px, gid);
}

// MARK: - 10. 物理光学散景（多边形叶片 + 猫眼旋焦 + 线性高光光斑）
struct OpticalBokehUniforms {
    float maxRadiusPx;
    float focusDepth;
    float focusRange;
    int blades;
    float highlightBoost;
    float catEye;
    float fullWidth;
    float fullHeight;
    float outOriginX;
    float outOriginY;
    int offsetX;
    int offsetY;
    int depthOffsetX;
    int depthOffsetY;
};

inline float cocForDepth(float d, float focusDepth, float focusRange, float maxRadiusPx) {
    float deadZone = max(0.02, focusRange * 0.75);
    float dist = max(0.0, abs(d - focusDepth) - deadZone);
    float span = max(0.12, 1.0 - deadZone);
    return clamp(dist / span, 0.0, 1.0) * maxRadiusPx;
}

kernel void bokeh_optical_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::read> depthTex [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant OpticalBokehUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int2 srcC = int2(gid) + int2(u.offsetX, u.offsetY);
    int2 depC = int2(gid) + int2(u.depthOffsetX, u.depthOffsetY);
    float4 centerPx = readClamped(src, srcC);
    float d0 = clamp(readClamped(depthTex, depC).r, 0.0, 1.0);
    float coc0 = cocForDepth(d0, u.focusDepth, u.focusRange, u.maxRadiusPx);
    if (coc0 < 0.75) {
        dst.write(centerPx, gid);
        return;
    }

    float2 uvNorm = (float2(float(gid.x) + u.outOriginX, float(gid.y) + u.outOriginY)
                     / max(float2(u.fullWidth, u.fullHeight), float2(1.0))) * 2.0 - 1.0;
    float2 catCenter = uvNorm * (u.catEye * 0.55);
    float catR2 = dot(uvNorm, uvNorm);
    float catScale = 1.0 / max(1.0 - min(catR2 * u.catEye * 0.35, 0.45), 0.55);

    float3 sumRGB = centerPx.rgb * 0.65;
    float sumW = 0.65;

    float sec = u.blades >= 5 ? (2.0 * M_PI_F / float(u.blades)) : 1.0;
    for (int k = 0; k < 37; k++) {
        float theta = float(k) * 2.39996323;
        float r = sqrt((float(k) + 0.5) / 37.0);
        float2 disk = float2(cos(theta), sin(theta)) * r;

        float pupilMask = 1.0;
        if (u.blades >= 5) {
            float ang = atan2(disk.y, disk.x);
            if (ang < 0.0) ang += 2.0 * M_PI_F;
            float la = fmod(ang, sec) - 0.5 * sec;
            float polyMax = cos(0.5 * sec) / max(cos(la), 0.35);
            pupilMask *= smoothstep(1.06, 0.88, r / polyMax);
        }
        if (u.catEye > 0.001) {
            float2 shifted = (disk - catCenter) * float2(catScale, 1.0);
            pupilMask *= smoothstep(1.05, 0.85, length(shifted));
        }
        if (pupilMask < 0.02) continue;

        int2 off = int2(round(disk.x * coc0), round(disk.y * coc0));
        float4 spx = readClamped(src, srcC + off);
        float ds = clamp(readClamped(depthTex, depC + off).r, 0.0, 1.0);
        float cocS = cocForDepth(ds, u.focusDepth, u.focusRange, u.maxRadiusPx);

        // 防前景渗色门控：锐利前景边界不向虚化背景溢色
        float bleed = (ds >= d0 - 0.06) ? 1.0 : smoothstep(0.15 * coc0, 0.45 * coc0, cocS);
        float luma = dot(max(spx.rgb, float3(0.0)), LUMA_W);
        float hiWeight = 1.0;
        if (luma > 0.65 && u.highlightBoost > 0.001) {
            hiWeight += pow(clamp((luma - 0.65) / 1.4, 0.0, 3.0), 1.35) * (u.highlightBoost * 4.5);
        }
        float w = pupilMask * mix(0.12, 1.0, bleed) * hiWeight;
        sumRGB += spx.rgb * w;
        sumW += w;
    }

    float3 outRGB = sumRGB / max(sumW, 1e-4);
    float edgeBlend = smoothstep(0.75, 2.2, coc0);
    dst.write(float4(mix(centerPx.rgb, outRGB, edgeBlend), centerPx.a), gid);
}

// MARK: - 11. 深度热力图叠加显示
struct DepthVisUniforms {
    float focusDepth;
    float focusRange;
    int offsetX;
    int offsetY;
    int depthOffsetX;
    int depthOffsetY;
};

kernel void depth_visualize_overlay(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::read> depthTex [[texture(1)]],
    texture2d<float, access::write> dst [[texture(2)]],
    constant DepthVisUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 px = readClamped(src, int2(gid) + int2(u.offsetX, u.offsetY));
    float d = clamp(readClamped(depthTex, int2(gid) + int2(u.depthOffsetX, u.depthOffsetY)).r, 0.0, 1.0);
    float diff = d - u.focusDepth;
    float dead = max(0.02, u.focusRange * 0.75);
    float focusBand = 1.0 - smoothstep(dead * 0.7, dead * 1.25, abs(diff));
    float3 nearCol = float3(0.95, 0.34, 0.10);
    float3 farCol  = float3(0.08, 0.38, 0.96);
    float3 focCol  = float3(0.92, 0.78, 0.16);
    float3 heat = diff < 0.0 ? mix(float3(0.55, 0.25, 0.15), nearCol, clamp(-diff * 2.0, 0.0, 1.0))
                             : mix(float3(0.12, 0.32, 0.55), farCol,  clamp(diff * 2.0, 0.0, 1.0));
    heat = mix(heat, focCol, focusBand);
    dst.write(float4(mix(px.rgb, heat, 0.45), px.a), gid);
}

// MARK: - 12. 线性 RAW 域保边双边降噪（YCbCr/YCoCg 对立色度-明度分离）
struct RawDenoiseUniforms {
    float amount;
    float detail;
    float lumaSigma;
    float chromaSigma;
    int chromaOnly;
    float stepPx;
    int offsetX;
    int offsetY;
};

inline float3 rgbToYCoCg(float3 c) {
    float y  = (c.r + 2.0 * c.g + c.b) * 0.25;
    float co = c.r - c.b;
    float cg = c.g - 0.5 * (c.r + c.b);
    return float3(y, co, cg);
}

inline float3 yCoCgToRGB(float3 ycc) {
    float tmp = ycc.x - 0.5 * ycc.z;
    float r = tmp + 0.5 * ycc.y;
    float g = ycc.x + 0.5 * ycc.z;
    float b = tmp - 0.5 * ycc.y;
    return float3(r, g, b);
}

kernel void raw_denoise_apply(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant RawDenoiseUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int2 c = int2(gid) + int2(u.offsetX, u.offsetY);
    float4 center = readClamped(src, c);
    float3 ycc0 = rgbToYCoCg(center.rgb);

    float lSigma = max(u.lumaSigma, 0.005);
    float cSigma = max(u.chromaSigma, 0.008);
    float invL2 = 1.0 / (2.0 * lSigma * lSigma);
    float invC2 = 1.0 / (2.0 * cSigma * cSigma);
    float stepS = max(u.stepPx, 1.0);

    float sumY = 0.0, wY = 0.0;
    float2 sumCC = float2(0.0);
    float wCC = 0.0;

    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            float d2 = float(dx * dx + dy * dy);
            float gW = exp(-d2 * 0.22);
            int2 p = c + int2(int(round(float(dx) * stepS)), int(round(float(dy) * stepS)));
            float3 ycc = rgbToYCoCg(readClamped(src, p).rgb);
            float dL = toPerceptual1(max(ycc.x, 0.0)) - toPerceptual1(max(ycc0.x, 0.0));
            float2 dCC = ycc.yz - ycc0.yz;

            float wy = gW * exp(-(dL * dL) * invL2);
            float wcc = gW * exp(-(dL * dL) * (invL2 * 0.35) - dot(dCC, dCC) * invC2);

            sumY += ycc.x * wy;
            wY += wy;
            sumCC += ycc.yz * wcc;
            wCC += wcc;
        }
    }

    float cleanY = sumY / max(wY, 1e-5);
    float2 cleanCC = sumCC / max(wCC, 1e-5);
    float3 denoisedYCC = float3(
        u.chromaOnly != 0 ? ycc0.x : mix(cleanY, ycc0.x, clamp(u.detail * 0.55, 0.0, 0.65)),
        mix(ycc0.yz, cleanCC, clamp(u.amount * 1.15, 0.0, 1.0))
    );
    float3 outRGB = yCoCgToRGB(denoisedYCC);
    if (min(center.r, min(center.g, center.b)) >= 0.0) {
        outRGB = max(outRGB, float3(0.0));
    }
    dst.write(float4(mix(center.rgb, outRGB, clamp(u.amount, 0.0, 1.0)), center.a), gid);
}

// MARK: - 13. 2x 超分方向性结构张量边缘增强
struct SuperResUniforms {
    float sharpen;
    float edgePreserve;
    int offsetX;
    int offsetY;
};

kernel void super_res_enhance(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant SuperResUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int2 c = int2(gid) + int2(u.offsetX, u.offsetY);
    float4 pC = readClamped(src, c);
    float3 c00 = readClamped(src, c + int2(-1, -1)).rgb;
    float3 c10 = readClamped(src, c + int2( 0, -1)).rgb;
    float3 c20 = readClamped(src, c + int2( 1, -1)).rgb;
    float3 c01 = readClamped(src, c + int2(-1,  0)).rgb;
    float3 c21 = readClamped(src, c + int2( 1,  0)).rgb;
    float3 c02 = readClamped(src, c + int2(-1,  1)).rgb;
    float3 c12 = readClamped(src, c + int2( 0,  1)).rgb;
    float3 c22 = readClamped(src, c + int2( 1,  1)).rgb;

    float y00 = dot(c00, LUMA_W), y10 = dot(c10, LUMA_W), y20 = dot(c20, LUMA_W);
    float y01 = dot(c01, LUMA_W), yC  = dot(pC.rgb, LUMA_W), y21 = dot(c21, LUMA_W);
    float y02 = dot(c02, LUMA_W), y12 = dot(c12, LUMA_W), y22 = dot(c22, LUMA_W);

    float gx = (y20 + 2.0 * y21 + y22) - (y00 + 2.0 * y01 + y02);
    float gy = (y02 + 2.0 * y12 + y22) - (y00 + 2.0 * y10 + y20);
    float gradMag = sqrt(gx * gx + gy * gy);
    float coh = smoothstep(0.015, 0.14, gradMag);

    // 邻域局部范围钳制防止振铃过冲
    float3 lo3 = min(min(min(c10, c12), min(c01, c21)), pC.rgb);
    float3 hi3 = max(max(max(c10, c12), max(c01, c21)), pC.rgb);
    float3 lap = pC.rgb - (c10 + c12 + c01 + c21) * 0.25;
    float gain = u.sharpen * mix(0.25, 1.0, coh * u.edgePreserve);
    float3 outRGB = clamp(pC.rgb + lap * gain, lo3 * 0.96, hi3 * 1.04 + float3(0.005));
    dst.write(float4(max(outRGB, float3(0.0)), pC.a), gid);
}
"""#
}
