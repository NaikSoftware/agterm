#version 140

// The lit rim of the glass, drawn over the window: a hairline that shines where the edge faces the light
// (top left) and, dimmer, where it faces away (bottom right), with a faint sheen just inside it.

uniform vec4 box;
uniform vec4 cornerRadius;
uniform float opacity;
uniform float edge; // the hairline's width, device pixels

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

void main(void)
{
    float d = sdfRoundedBox(vertex, box.xy, box.zw, cornerRadius);
    if (d > 0.5 || d < -edge * 6.0) {
        discard;
    }
    const float e = 1.0;
    vec2 grad = vec2(sdfRoundedBox(vertex + vec2(e, 0.0), box.xy, box.zw, cornerRadius) - sdfRoundedBox(vertex - vec2(e, 0.0), box.xy, box.zw, cornerRadius),
                     sdfRoundedBox(vertex + vec2(0.0, e), box.xy, box.zw, cornerRadius) - sdfRoundedBox(vertex - vec2(0.0, e), box.xy, box.zw, cornerRadius));
    vec2 outward = length(grad) > 0.0001 ? normalize(grad) : vec2(0.0);
    float facing = dot(outward, normalize(vec2(-1.0, -1.0)));
    float light = facing > 0.0 ? 0.30 + 0.70 * pow(facing, 1.5) : 0.18 + 0.40 * pow(-facing, 2.0);
    float line = 1.0 - smoothstep(0.0, edge, -d);
    float sheen = (1.0 - smoothstep(0.0, edge * 6.0, -d)) * 0.10;
    float a = clamp(line * light + sheen * light, 0.0, 1.0) * opacity;
    a *= 1.0 - clamp(0.5 + d / max(fwidth(d), 0.0001), 0.0, 1.0);
    fragColor = vec4(vec3(a), a);
}
