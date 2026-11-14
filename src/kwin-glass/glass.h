/*
    agterm's glass: KWin's blur effect (6.8.2), narrowed to agterm windows, with a per-window strength and
    a refracting edge like a slab of glass.

    SPDX-FileCopyrightText: 2010 Fredrik Höglund <fredrik@kde.org>
    SPDX-FileCopyrightText: 2018 Alex Nemeth <alex.nemeth329@gmail.com>
    SPDX-FileCopyrightText: 2026 NaikSoftware

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#pragma once

#include "effect/effect.h"
#include "opengl/glutils.h"
#include "scene/item.h"

#include <QDBusContext>
#include <QHash>
#include <QList>

#include <unordered_map>

namespace KWin
{

class BackgroundEffectItem;

struct GlassRenderData
{
    /// Dual Kawase targets; the first holds the unblurred background behind the window
    std::vector<std::unique_ptr<GLTexture>> textures;
    std::vector<std::unique_ptr<GLFramebuffer>> framebuffers;
};

struct GlassLook
{
    int blur = 0; // 0..15, KWin's own blur strength steps; 0 = clear glass
    double refraction = 0; // 0..1
};

struct GlassWindowData
{
    GlassLook look;
    std::unordered_map<RenderView *, GlassRenderData> render;
    std::unique_ptr<BackgroundEffectItem> blurItem;
    QList<RectF> shape; // what the last blur pass painted, in device pixels relative to background
    Rect background; // logical, on screen
    Rect scaledBackground;
};

class GlassEffect : public Effect, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.agterm.Glass")

public:
    GlassEffect();
    ~GlassEffect() override;

    static bool supported();

    void prePaintScreen(ScreenPrePaintData &data) override;
    bool drawWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data) override;
    bool isActive() const override;
    int requestedEffectChainPosition() const override
    {
        return 21; // right after KWin's blur, which leaves agterm windows alone
    }
    bool blocksDirectScanout() const override
    {
        return false;
    }

public Q_SLOTS:
    // the calling process's agterm windows get this look; 0 and 0 turn the glass off. blur and refraction are 0..100.
    Q_SCRIPTABLE void setGlass(int blur, int refraction);
    Q_SCRIPTABLE QString version() const;

private:
    void windowAdded(EffectWindow *w);
    void windowDeleted(EffectWindow *w);
    void update(EffectWindow *w);
    bool shouldBlur(const EffectWindow *w, int mask, const WindowPaintData &data) const;
    void blur(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data);
    void rim(const RenderViewport &viewport, EffectWindow *w, WindowPaintData &data);
    void initBlurStrengthValues();

    struct Pass
    {
        std::unique_ptr<GLShader> shader;
        int mvpMatrix = -1, offset = -1, halfpixel = -1;
    };
    Pass m_downsamplePass, m_upsamplePass;
    struct : Pass
    {
        int box = -1, cornerRadius = -1, opacity = -1, refraction = -1, edge = -1, texSize = -1, valid = -1;
    } m_glassPass;
    struct : Pass
    {
        int box = -1, cornerRadius = -1, opacity = -1, edge = -1;
    } m_rimPass;

    bool m_valid = false;
    RenderView *m_currentView = nullptr;
    QHash<qint64, GlassLook> m_looks; // by process id

    struct OffsetStruct
    {
        float minOffset;
        float maxOffset;
        int expandSize;
    };
    QList<OffsetStruct> blurOffsets;
    struct BlurValuesStruct
    {
        int iteration;
        float offset;
    };
    QList<BlurValuesStruct> blurStrengthValues;

    std::unordered_map<EffectWindow *, GlassWindowData> m_windows;
};

} // namespace KWin
