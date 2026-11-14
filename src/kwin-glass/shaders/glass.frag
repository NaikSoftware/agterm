#version 140

// The blurred (or clear) background behind an agterm window, seen through a slab of glass: across a bevel
// along the edge the surface curves away, so what is under the rim is pulled in from further inside and
// splits slightly by colour, and the curve catches light.

uniform sampler2D texUnit;
uniform float offset;
uniform vec2 halfpixel;
uniform vec4 box;          // centre and half size of the glass, device pixels
uniform vec4 cornerRadius;
uniform float opacity;
uniform float refraction;  // the strongest bend, device pixels
uniform float edge;        // bevel width, device pixels
uniform vec2 texSize;      // the background texture, device pixels

in vec2 uv;
in vec2 vertex;

out vec4 fragColor;

float sdfRoundedBox(vec2 position, vec2 center, vec2 extents, vec4 radius)
{
    vec2 p = position - center;
    float r = p.x > 0.0 ? (p.y < 0.0 ? radius.y : radius.w) : (p.y < 0.0 ? radius.x : radius.z);
    vec2 q = abs(p) - extents + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

vec4 kawase(vec2 at)
{
    vec4 sum = texture(texUnit, at + vec2(-halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, at + vec2(-halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(0.0, halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, at + vec2(halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, at + vec2(halfpixel.x, -halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(0.0, -halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, at + vec2(-halfpixel.x, -halfpixel.y) * offset) * 2.0;
    return sum / 12.0;
}

void main(void)
{
    float d = sdfRoundedBox(vertex, box.xy, box.zw, cornerRadius);
    float t = 1.0 - clamp(-d / max(edge, 1.0), 0.0, 1.0);
    t = smoothstep(0.0, 1.0, t);
    float bevel = t * t; // the slab thins toward the edge, so the bend grows across the whole bevel

    vec4 color;
    if (bevel > 0.0005 && refraction > 0.0) {
        // the bend turns around a rounder outline than the window's own corners, or a square corner would crease it
        const float e = 1.0;
        vec4 lensRadius = max(cornerRadius, vec4(min(edge * 1.5, min(box.z, box.w))));
        vec2 grad = vec2(sdfRoundedBox(vertex + vec2(e, 0.0), box.xy, box.zw, lensRadius) - sdfRoundedBox(vertex - vec2(e, 0.0), box.xy, box.zw, lensRadius),
                         sdfRoundedBox(vertex + vec2(0.0, e), box.xy, box.zw, lensRadius) - sdfRoundedBox(vertex - vec2(0.0, e), box.xy, box.zw, lensRadius));
        vec2 outward = length(grad) > 0.0001 ? normalize(grad) : vec2(0.0);
        vec2 shift = -outward * refraction * bevel; // device pixels, y down
        vec2 duv = vec2(shift.x / texSize.x, -shift.y / texSize.y);
        vec4 g = kawase(clamp(uv + duv, 0.0, 1.0));
        float r = kawase(clamp(uv + duv * 1.18, 0.0, 1.0)).r; // red bends most
        float b = kawase(clamp(uv + duv * 0.82, 0.0, 1.0)).b;
        color = vec4(r, g.g, b, g.a);
        color.rgb += color.rgb * bevel * 0.45; // the curve gathers light
    } else {
        color = kawase(uv);
    }

    fragColor = color * opacity;
    float df = fwidth(d);
    fragColor *= 1.0 - clamp(0.5 + d / max(df, 0.0001), 0.0, 1.0);
}
