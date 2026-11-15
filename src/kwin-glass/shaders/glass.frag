#version 140

// The blurred background behind an agterm window: the last Dual Kawase upsample, cut to the window's rounded shape.

uniform sampler2D texUnit;
uniform float offset;
uniform vec2 halfpixel;
uniform vec4 box;          // centre and half size of the window, device pixels
uniform vec4 cornerRadius;
uniform float opacity;

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
    vec4 sum = texture(texUnit, uv + vec2(-halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, uv + vec2(-halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, uv + vec2(0.0, halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, uv + vec2(halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, uv + vec2(halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, uv + vec2(halfpixel.x, -halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, uv + vec2(0.0, -halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, uv + vec2(-halfpixel.x, -halfpixel.y) * offset) * 2.0;

    float d = sdfRoundedBox(vertex, box.xy, box.zw, cornerRadius);
    fragColor = sum / 12.0 * opacity;
    fragColor *= 1.0 - clamp(0.5 + d / max(fwidth(d), 0.0001), 0.0, 1.0);
}
