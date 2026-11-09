#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
using namespace coreimage;

// 连续高光扩展：从中间调开始平滑增长，没有阈值触发点。
inline float hdrExpansionGain(float peak) {
    float p = clamp(peak, 0.0, 1.0);
    float p2 = p * p;
    float p4 = p2 * p2;
    return 3.0 * p4 * p2;
}

[[stitchable]] float4 adaptiveSDRBase(sample_t pixel) {
    float4 c = unpremultiply(pixel);
    float headroom = max(1.0,max(c.r,max(c.g,c.b)));
    c.rgb /= headroom;
    return premultiply(c);
}
[[stitchable]] float4 adaptiveHDRRestore(sample_t original,sample_t filtered) {
    float4 c = unpremultiply(original), f = unpremultiply(filtered);
    f.rgb *= max(1.0,max(c.r,max(c.g,c.b)));
    return premultiply(f);
}

// 线性浮点亮度肩部：保留高光层次、RGB比例和黑位，不把HDR简单截到1。
[[stitchable]] float4 adaptiveDynamic(sample_t pixel, float shadowEV, float deepShadowEV, float knee, float cap, float shoulder) {
    float4 c = unpremultiply(pixel);
    float y = max(dot(c.rgb,float3(0.2126,0.7152,0.0722)),0.0);
    // 有理曲线在0到锚点严格单调，黑色仍为0；最暗细节也能提亮。
    // 旧版分段增益既跳过深暗部，又可能让相邻亮度次序反转。
    float gain = exp2(shadowEV);
    float raised = y < 0.45 ? y*gain/(1.0+(gain-1.0)*y/0.45) : y;
    // 深暗部独立恢复；0.12以上保持不变，避免中位数正常时整张继续提亮。
    float deepGain = exp2(deepShadowEV);
    raised = raised < 0.12 ? raised*deepGain/(1.0+(deepGain-1.0)*raised/0.12) : raised;
    float mapped = raised <= knee ? raised : knee+(cap-knee)*(1.0-exp(-(raised-knee)/shoulder));
    c.rgb *= y > 0.000001 ? mapped/y : 1.0;
    return premultiply(c);
}

[[stitchable]] float4 chromaticShift(coreimage::sampler image, float amount, float2 center, coreimage::destination dest) {
            float2 p = dest.coord();
            float4 r = image.sample(image.transform(p - (p - center) * amount));
            float4 g = image.sample(image.coord());
            float4 b = image.sample(image.transform(p + (p - center) * amount));
            return float4(r.r, g.g, b.b, g.a);
        }

[[stitchable]] float4 bloomLayer(coreimage::sample_t bloom, coreimage::sample_t base, coreimage::destination dest) { return float4(max(float3(0.0), bloom.rgb - base.rgb), 1.0); }

[[stitchable]] float4 addLight(coreimage::sample_t base, coreimage::sample_t light, coreimage::destination dest) { float4 c = unpremultiply(base); c.rgb += unpremultiply(light).rgb; return premultiply(c); }

[[stitchable]] float4 restoreAlpha(coreimage::sample_t color, coreimage::sample_t original, coreimage::destination dest) { float4 c = unpremultiply(color); c.a = original.a; return premultiply(c); }

[[stitchable]] float4 lights(coreimage::sample_t pixel, float amount, coreimage::destination dest) { float3 c = unpremultiply(pixel).rgb; float m = smoothstep(0.45, 0.90, dot(c, float3(0.2126, 0.7152, 0.0722))) * amount; return float4(m, m * 0.32, m * 0.08, 1.0); }

[[stitchable]] float4 filmGrain(coreimage::sample_t pixel, float cell, float amount, float saturation, float phase, coreimage::destination dest) {
            float2 q = dest.coord() / cell + float2(phase, phase * 0.71);
            float2 p = floor(q);
            float2 f = fract(q); f = f * f * (3.0 - 2.0 * f);
            float4 offsets = float4(0.0, 12.9898, 78.233, 91.2228);
            float4 a = fract(sin(float4(dot(p, float2(12.9898, 78.233))) + offsets) * 43758.5453);
            float4 b = fract(sin(float4(dot(p + float2(17.0, 31.0), float2(12.9898, 78.233))) + offsets) * 43758.5453);
            float4 d = fract(sin(float4(dot(p + float2(53.0, 7.0), float2(12.9898, 78.233))) + offsets) * 43758.5453);
            float3 noise = float3(mix(mix(a.x, a.y, f.x), mix(a.z, a.w, f.x), f.y),
                              mix(mix(b.x, b.y, f.x), mix(b.z, b.w, f.x), f.y),
                              mix(mix(d.x, d.y, f.x), mix(d.z, d.w, f.x), f.y)) - float3(0.5);
            // Separate luminance and chroma: the upper range intentionally produces
            // visible colour granules, without increasing global image saturation.
            float mono = noise.x;
            float3 chroma = noise - float3(dot(noise, float3(0.2126, 0.7152, 0.0722)));
            noise = float3(mono) + chroma * (4.0 * clamp(saturation, 0.0, 1.0));
            float4 c = unpremultiply(pixel);
            float l = clamp(dot(c.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
            float density = sqrt(max(0.0, l * (1.0 - l))) * 2.0;
            c.rgb = max(float3(0.0), c.rgb + noise * amount * density);
            return premultiply(c);
        }

[[stitchable]] float4 focusPeak(coreimage::sample_t base, coreimage::sample_t edge, coreimage::destination dest) {
            float4 c = unpremultiply(base);
            float sharp = dot(edge.rgb, float3(0.2126, 0.7152, 0.0722));
            float mask = smoothstep(0.10, 0.24, sharp) * 0.9;
            c.rgb = mix(c.rgb, float3(1.0, 0.08, 0.025), mask);
            return premultiply(c);
        }


// Perceptual luminance curves with a linear HDR extension. Never clamp scene
// highlights to 1; all colour channels keep their chromatic relationships.
[[stitchable]] float4 proTone(coreimage::sample_t pixel, float4 points, float white, float saturation, float protectHighlights, coreimage::destination dest) {
    float4 c = unpremultiply(pixel);
    float lum = max(dot(c.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0);
    if (protectHighlights > 0.0 && lum >= 1.0) {
        return pixel;
    }
    float x = lum <= 0.0031308 ? lum * 12.92 : 1.055 * pow(lum, 1.0 / 2.4) - 0.055;
    float ys[5] = { points.x, points.y, points.z, points.w, white };
    float d[4];
    for (int i = 0; i < 4; ++i) { d[i] = (ys[i + 1] - ys[i]) * 4.0; }
    float mapped;
    if (x <= 1.0) {
        float m[5]; m[0] = d[0]; m[4] = d[3];
        for (int i = 1; i < 4; ++i) {
            m[i] = d[i - 1] * d[i] <= 0.0 ? 0.0 : 2.0 * d[i - 1] * d[i] / (d[i - 1] + d[i]);
        }
        int index = min(int(floor(x * 4.0)), 3);
        float t = x * 4.0 - float(index), t2 = t * t, t3 = t2 * t;
        float y = (2.0 * t3 - 3.0 * t2 + 1.0) * ys[index] +
            (t3 - 2.0 * t2 + t) * 0.25 * m[index] +
            (-2.0 * t3 + 3.0 * t2) * ys[index + 1] + (t3 - t2) * 0.25 * m[index + 1];
        mapped = y <= 0.04045 ? y / 12.92 : pow((y + 0.055) / 1.055, 2.4);
    } else {
        float linearWhite = white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4);
        float decodeSlope = white <= 0.04045 ? 1.0 / 12.92 : (2.4 / 1.055) * pow((white + 0.055) / 1.055, 1.4);
        mapped = linearWhite + (lum - 1.0) * d[3] * decodeSlope / 2.2748815;
    }
    // 线性亮度接近参考白时平滑减弱影调，保留源图的高光亮度和色彩。
    float highlightWeight = protectHighlights * smoothstep(0.5, 1.0, lum);
    mapped = mix(mapped, lum, highlightWeight);
    saturation = mix(saturation, 1.0, highlightWeight);
    float scale = mapped / max(lum, 0.005);
    c.rgb = float3(mapped) + (c.rgb - float3(lum)) * scale * saturation;
    return premultiply(c);
}



[[stitchable]] float4 hdrExpand(sample_t image, float maxGain) {
    float4 c = unpremultiply(image);
    float peak = max(c.r, max(c.g, c.b));
    float gain = hdrExpansionGain(peak) / 3.0 * maxGain;
    c.rgb *= 1.0 + gain;
    return float4(c.rgb, image.a);
}

[[stitchable]] float4 hdrSoftShoulder(sample_t image, float knee, float targetHeadroom) {
    float4 c = unpremultiply(image);
    float3 rgb = max(c.rgb, 0.0);
    // 最大通道作为参考，避免彩色高光在SDR编码时单通道先被截断。
    float y = max(rgb.r, max(rgb.g, rgb.b));
    if (y > knee && y > 0.0001) {
        float range = max(targetHeadroom - knee, 0.001);
        float mapped = knee + range * (1.0 - exp(-(y - knee) / range));
        rgb *= mapped / y;
    }
    return float4(rgb, c.a);
}

[[stitchable]] float4 hdrRestoreSourceGain(sample_t original, sample_t base, sample_t adjusted) {
    float3 source = max(unpremultiply(original).rgb, 0.0);
    float3 reference = max(unpremultiply(base).rgb, 0.0);
    float sourcePeak = max(source.r, max(source.g, source.b));
    float basePeak = max(reference.r, max(reference.g, reference.b));
    float gain = basePeak > 0.0001 ? max(1.0, sourcePeak / basePeak) : 1.0;
    float4 result = unpremultiply(adjusted);
    result.rgb = max(result.rgb, 0.0) * gain;
    return premultiply(result);
}

// Log2 uses Apple Wide Gamut primaries; decode to scene linear, convert to
// BT.2020, then re-encode the same Apple Log transfer for Log1-compatible LUTs.
[[stitchable]] float4 appleLog2ToAppleLog(sample_t image, float3 r0, float3 r1, float3 r2) {
    const float R0 = -0.05641088;
    const float Rt = 0.01;
    const float C = 47.28711236;
    const float Beta = 0.00964052;
    const float Gamma = 0.08550479;
    const float Delta = 0.69336945;
    const float Pt = C * (Rt - R0) * (Rt - R0);
    float4 c = unpremultiply(image);
    float3 p = clamp(c.rgb, 0.0, 1.0);
    float3 linear;
    for (int i = 0; i < 3; i++) {
        float v = p[i];
        linear[i] = v >= Pt ? pow(2.0, (v - Delta) / Gamma) - Beta
                            : (v >= 0.0 ? sqrt(v / C) + R0 : R0);
    }
    linear = max(linear, 0.0);
    float3 bt = float3(dot(r0, linear), dot(r1, linear), dot(r2, linear));
    float3 encoded;
    for (int i = 0; i < 3; i++) {
        float v = max(bt[i], 0.0);
        encoded[i] = v >= Rt ? Gamma * log2(v + Beta) + Delta
                             : (v >= R0 ? C * (v - R0) * (v - R0) : 0.0);
    }
    return float4(clamp(encoded, 0.0, 1.0), c.a);
}

[[stitchable]] float4 filterStrength(sample_t original, sample_t filtered, float strength) {
    // 浓度最高 1.3 倍外推；负值钳到 0，保留 >1 高光。
    float3 mixed = mix(original.rgb, filtered.rgb, strength);
    return float4(max(mixed, 0.0), original.a);
}

// 局部高亮还必须具有有限的空间范围；用两圈32方向检查抑制面光源、角点与细长亮边。
// 这是基于画面尺度的孤立性近似，不声称能判断真实灯具的物理类型。
[[stitchable]] float4 aperturePointSeeds(coreimage::sampler image, coreimage::sampler local, float radius, coreimage::destination dest) {
    float3 c = unpremultiply(image.sample(image.coord())).rgb;
    float peak = max(c.r, max(c.g, c.b));
    float average = dot(unpremultiply(local.sample(local.coord())).rgb, float3(0.2126, 0.7152, 0.0722));
    float mask = smoothstep(0.62, 0.96, peak) * smoothstep(0.025, 0.16, peak - average);
    if (mask < 0.0001) { return float4(0.0, 0.0, 0.0, 1.0); }
    float surrounding = 0.0;
    for (int n = 0; n < 32; n++) {
        float angle = float(n) * 0.196349540849362;
        float2 direction = float2(cos(angle), sin(angle));
        float3 nearRing = unpremultiply(image.sample(image.transform(dest.coord() + direction * radius))).rgb;
        float3 farRing = unpremultiply(image.sample(image.transform(dest.coord() + direction * radius * 1.45))).rgb;
        surrounding = max(surrounding, max(max(nearRing.r, nearRing.g), nearRing.b));
        surrounding = max(surrounding, max(max(farRing.r, farRing.g), farRing.b));
    }
    // 保守排除仍连接高亮背景的候选，宁可少生成星芒，不把屏幕边框划成光线。
    float isolated = 1.0 - smoothstep(0.3, 0.65, surrounding);
    return float4(c * mask * isolated, 1.0);
}
[[stitchable]] float4 apertureStarAdd(coreimage::sample_t original, coreimage::sample_t rays, float amount, coreimage::destination dest) {
    float4 c = unpremultiply(original);
    c.rgb += max(float3(0.0), unpremultiply(rays).rgb) * amount;
    return premultiply(c);
}
