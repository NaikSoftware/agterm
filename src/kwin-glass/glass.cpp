/*
    SPDX-FileCopyrightText: 2010 Fredrik Höglund <fredrik@kde.org>
    SPDX-FileCopyrightText: 2011 Philipp Knechtges <philipp-dev@knechtges.com>
    SPDX-FileCopyrightText: 2018 Alex Nemeth <alex.nemeth329@gmail.com>
    SPDX-FileCopyrightText: 2026 NaikSoftware

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "glass.h"

#include "core/rendertarget.h"
#include "core/renderviewport.h"
#include "effect/effecthandler.h"
#include "opengl/eglcontext.h"
#include "scene/backgroundeffectitem.h"
#include "scene/windowitem.h"
#include "window.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QLoggingCategory>
#include <QMatrix4x4>
#include <cmath>

Q_LOGGING_CATEGORY(AGTERM_GLASS, "agterm_glass", QtWarningMsg)

static void ensureResources()
{
    Q_INIT_RESOURCE(glass);
}

namespace KWin
{

static const QString s_path = QStringLiteral("/org/agterm/Glass");
static constexpr float s_bevel = 44; // logical pixels of curved glass along each edge
static constexpr float s_reach = 70; // logical pixels beyond the edge the rim shows at full refraction
static constexpr float s_hairline = 1.2;

GlassEffect::GlassEffect()
{
    ensureResources();
    auto load = [](Pass &pass, const QString &vertex, const QString &fragment) {
        pass.shader = ShaderManager::instance()->generateShaderFromFile(ShaderTrait::MapTexture, QStringLiteral(":/effects/agtermglass/shaders/") + vertex,
                                                                        QStringLiteral(":/effects/agtermglass/shaders/") + fragment);
        if (!pass.shader) {
            qCWarning(AGTERM_GLASS) << "Failed to load" << fragment;
            return false;
        }
        pass.mvpMatrix = pass.shader->uniformLocation("modelViewProjectionMatrix");
        pass.offset = pass.shader->uniformLocation("offset");
        pass.halfpixel = pass.shader->uniformLocation("halfpixel");
        return true;
    };
    if (!load(m_downsamplePass, QStringLiteral("vertex.vert"), QStringLiteral("downsample.frag"))
        || !load(m_upsamplePass, QStringLiteral("vertex.vert"), QStringLiteral("upsample.frag"))
        || !load(m_glassPass, QStringLiteral("glass.vert"), QStringLiteral("glass.frag"))
        || !load(m_rimPass, QStringLiteral("glass.vert"), QStringLiteral("rim.frag"))) {
        return;
    }
    m_glassPass.box = m_glassPass.shader->uniformLocation("box");
    m_glassPass.cornerRadius = m_glassPass.shader->uniformLocation("cornerRadius");
    m_glassPass.opacity = m_glassPass.shader->uniformLocation("opacity");
    m_glassPass.refraction = m_glassPass.shader->uniformLocation("refraction");
    m_glassPass.edge = m_glassPass.shader->uniformLocation("edge");
    m_glassPass.texSize = m_glassPass.shader->uniformLocation("texSize");
    m_glassPass.valid = m_glassPass.shader->uniformLocation("valid");
    m_rimPass.box = m_rimPass.shader->uniformLocation("box");
    m_rimPass.cornerRadius = m_rimPass.shader->uniformLocation("cornerRadius");
    m_rimPass.opacity = m_rimPass.shader->uniformLocation("opacity");
    m_rimPass.edge = m_rimPass.shader->uniformLocation("edge");

    initBlurStrengthValues();

    connect(effects, &EffectsHandler::windowAdded, this, &GlassEffect::windowAdded);
    connect(effects, &EffectsHandler::windowDeleted, this, &GlassEffect::windowDeleted);
    connect(effects, &EffectsHandler::viewRemoved, this, [this](RenderView *view) {
        for (auto &[window, data] : m_windows) {
            if (auto it = data.render.find(view); it != data.render.end()) {
                effects->makeOpenGLContextCurrent();
                data.render.erase(it);
            }
        }
    });
    QDBusConnection::sessionBus().registerObject(s_path, this, QDBusConnection::ExportScriptableSlots);
    m_valid = true;
}

GlassEffect::~GlassEffect()
{
    QDBusConnection::sessionBus().unregisterObject(s_path);
}

bool GlassEffect::supported()
{
    return effects->isOpenGLCompositing();
}

QString GlassEffect::version() const
{
    return QStringLiteral(KWIN_PLUGIN_VERSION_STRING);
}

void GlassEffect::setGlass(int blur, int refraction)
{
    if (!calledFromDBus()) {
        return;
    }
    // the caller is whoever owns the D-Bus name; any session app may call, so it only ever styles its own windows
    const auto pid = connection().interface()->servicePid(message().service());
    if (!pid.isValid()) {
        return;
    }
    blur = std::clamp(blur, 0, 100);
    refraction = std::clamp(refraction, 0, 100);
    if (!blur && !refraction) {
        m_looks.remove(pid.value());
    } else {
        // 1..100 maps onto KWin's own 15 blur steps
        m_looks.insert(pid.value(), GlassLook{blur ? std::clamp(int(std::ceil(blur * 15 / 100.0)), 1, 15) : 0, refraction / 100.0});
    }
    for (EffectWindow *w : effects->stackingOrder()) {
        if (qint64(w->pid()) == qint64(pid.value())) {
            update(w);
        }
    }
}

void GlassEffect::initBlurStrengthValues()
{
    // KWin's blur: 15 evenly spread steps over the Dual Kawase iterations and offsets that stay artefact free
    const int numOfBlurSteps = 15;
    int remainingSteps = numOfBlurSteps;
    blurOffsets.append({1.0, 2.0, 10}); // Down sample size / 2
    blurOffsets.append({2.0, 3.0, 20}); // Down sample size / 4
    blurOffsets.append({2.0, 5.0, 50}); // Down sample size / 8
    blurOffsets.append({3.0, 8.0, 150}); // Down sample size / 16
    float offsetSum = 0;
    for (const auto &o : std::as_const(blurOffsets)) {
        offsetSum += o.maxOffset - o.minOffset;
    }
    for (int i = 0; i < blurOffsets.size(); i++) {
        int iterationNumber = std::ceil((blurOffsets[i].maxOffset - blurOffsets[i].minOffset) / offsetSum * numOfBlurSteps);
        remainingSteps -= iterationNumber;
        if (remainingSteps < 0) {
            iterationNumber += remainingSteps;
        }
        const float offsetDifference = blurOffsets[i].maxOffset - blurOffsets[i].minOffset;
        for (int j = 1; j <= iterationNumber; j++) {
            blurStrengthValues.append({i + 1, blurOffsets[i].minOffset + (offsetDifference / iterationNumber) * j});
        }
    }
}

void GlassEffect::windowAdded(EffectWindow *w)
{
    update(w);
}

void GlassEffect::windowDeleted(EffectWindow *w)
{
    if (auto it = m_windows.find(w); it != m_windows.end()) {
        effects->makeOpenGLContextCurrent();
        m_windows.erase(it);
    }
}

void GlassEffect::update(EffectWindow *w)
{
    const auto look = m_looks.constFind(w->pid());
    // the main windows only: agterm's dialogs and popups are opaque
    if (look == m_looks.constEnd() || !w->isNormalWindow() || !w->windowClass().contains(QLatin1String("agterm"), Qt::CaseInsensitive)) {
        if (m_windows.contains(w)) {
            windowDeleted(w);
            w->addRepaintFull();
        }
        return;
    }
    GlassWindowData &data = m_windows[w];
    data.look = *look;
    if (!data.blurItem) {
        data.blurItem = std::make_unique<BackgroundEffectItem>(w->windowItem());
    }
    // what changes under the window reaches it through the blur kernel and, further, through the bent rim
    const int blurReach = data.look.blur ? blurOffsets[blurStrengthValues[data.look.blur - 1].iteration - 1].expandSize : 0;
    const int reach = int(std::ceil(s_reach * 1.2 * data.look.refraction)) + 2;
    data.blurItem->setPixelsToExpandRepaintsBelowOpaqueRegions(std::max(blurReach, reach));
    data.blurItem->setEffectBoundingRect(w->contentsRect().adjusted(-reach, -reach, reach, reach));
    w->addRepaintFull();
}

bool GlassEffect::isActive() const
{
    return m_valid && !m_windows.empty() && !effects->isScreenLocked();
}

void GlassEffect::prePaintScreen(ScreenPrePaintData &data)
{
    m_currentView = data.view;
    effects->prePaintScreen(data);
}

bool GlassEffect::shouldBlur(const EffectWindow *w, int mask, const WindowPaintData &data) const
{
    if (effects->activeFullScreenEffect() && !w->data(WindowForceBlurRole).toBool()) {
        return false;
    }
    const bool scaled = !qFuzzyCompare(data.xScale(), 1.0) && !qFuzzyCompare(data.yScale(), 1.0);
    const bool translated = data.xTranslation() || data.yTranslation();
    return !((scaled || translated || (mask & PAINT_WINDOW_TRANSFORMED)) && !w->data(WindowForceBlurRole).toBool());
}

bool GlassEffect::drawWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data)
{
    blur(renderTarget, viewport, w, mask, deviceRegion, data);
    const bool drawn = effects->drawWindow(renderTarget, viewport, w, mask, deviceRegion, data);
    rim(viewport, w, data);
    return drawn;
}

// fills the streaming buffer with the shape (device pixels, relative to the background) as triangles,
// after an optional offscreen quad covering the whole background
static bool upload(GLVertexBuffer *vbo, const QList<RectF> &shape, const Rect &background, const Rect &scaledBackground, bool withQuad)
{
    vbo->reset();
    vbo->setAttribLayout(std::span(GLVertexBuffer::GLVertex2DLayout), sizeof(GLVertex2D));
    auto result = vbo->map<GLVertex2D>((withQuad ? 6 : 0) + shape.size() * 6);
    if (!result) {
        return false;
    }
    auto map = *result;
    size_t i = 0;
    auto quad = [&](float x0, float y0, float x1, float y1, float w, float h) {
        const float u0 = x0 / w, v0 = 1.0f - y0 / h, u1 = x1 / w, v1 = 1.0f - y1 / h;
        map[i++] = GLVertex2D{.position = QVector2D(x0, y0), .texcoord = QVector2D(u0, v0)};
        map[i++] = GLVertex2D{.position = QVector2D(x1, y1), .texcoord = QVector2D(u1, v1)};
        map[i++] = GLVertex2D{.position = QVector2D(x0, y1), .texcoord = QVector2D(u0, v1)};
        map[i++] = GLVertex2D{.position = QVector2D(x0, y0), .texcoord = QVector2D(u0, v0)};
        map[i++] = GLVertex2D{.position = QVector2D(x1, y0), .texcoord = QVector2D(u1, v0)};
        map[i++] = GLVertex2D{.position = QVector2D(x1, y1), .texcoord = QVector2D(u1, v1)};
    };
    if (withQuad) {
        quad(0, 0, background.width(), background.height(), background.width(), background.height());
    }
    for (const RectF &rect : shape) {
        quad(rect.left(), rect.top(), rect.right(), rect.bottom(), scaledBackground.width(), scaledBackground.height());
    }
    vbo->unmap();
    return true;
}

void GlassEffect::blur(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data)
{
    auto it = m_windows.find(w);
    if (it == m_windows.end()) {
        return;
    }
    GlassWindowData &glass = it->second;
    glass.shape.clear();
    GlassRenderData &renderInfo = glass.render[m_currentView];
    if (!shouldBlur(w, mask, data)) {
        return;
    }

    const size_t iterations = glass.look.blur ? blurStrengthValues[glass.look.blur - 1].iteration : 0;
    const float offset = glass.look.blur ? blurStrengthValues[glass.look.blur - 1].offset : 0;

    // the whole client area is glass; the server-side title bar paints over its own part
    RegionF blurShape(w->contentsRect());
    blurShape.translate(w->pos());
    // the rim shows what lies just beyond the edge, so the captured background reaches past the window
    const int margin = int(std::ceil(s_reach * 1.2 * glass.look.refraction));
    const Rect backgroundRect = blurShape.boundingRect().rounded().adjusted(-margin, -margin, margin, margin);
    const Rect scaledBackgroundRect = backgroundRect.scaled(viewport.scale()).rounded();
    const Rect deviceBackgroundRect = viewport.mapToDeviceCoordinates(backgroundRect).rounded();
    const auto opacity = w->opacity() * data.opacity();

    QList<RectF> effectiveShape;
    if (deviceRegion != Region::infinite()) {
        for (const Rect &clipRect : deviceRegion.rects()) {
            const RectF deviceClipRect = clipRect.translated(-deviceBackgroundRect.topLeft());
            for (const RectF &shapeRect : blurShape.rects()) {
                const RectF deviceShapeRect = shapeRect.translated(-backgroundRect.topLeft()).scaled(viewport.scale()).rounded();
                if (const RectF intersected = deviceClipRect.intersected(deviceShapeRect); !intersected.isEmpty()) {
                    effectiveShape.append(intersected);
                }
            }
        }
    } else {
        for (const RectF &rect : blurShape.rects()) {
            effectiveShape.append(rect.translated(-backgroundRect.topLeft()).scaled(viewport.scale()).rounded());
        }
    }
    if (effectiveShape.isEmpty()) {
        return;
    }

    GLenum textureFormat = GL_RGBA8;
    if (renderTarget.texture()) {
        textureFormat = renderTarget.texture()->internalFormat();
    }
    if (renderInfo.framebuffers.size() != iterations + 1 || renderInfo.textures[0]->size() != backgroundRect.size() || renderInfo.textures[0]->internalFormat() != textureFormat) {
        renderInfo.framebuffers.clear();
        renderInfo.textures.clear();
        glClearColor(0, 0, 0, 0);
        for (size_t i = 0; i <= iterations; ++i) {
            auto texture = GLTexture::allocate(textureFormat, backgroundRect.size() / (1 << i));
            if (!texture) {
                qCWarning(AGTERM_GLASS) << "Failed to allocate an offscreen texture";
                return;
            }
            texture->setFilter(GL_LINEAR);
            texture->setWrapMode(GL_CLAMP_TO_EDGE);
            auto framebuffer = std::make_unique<GLFramebuffer>(texture.get());
            if (!framebuffer->valid()) {
                qCWarning(AGTERM_GLASS) << "Failed to create an offscreen framebuffer";
                return;
            }
            EglContext::currentContext()->pushFramebuffer(framebuffer.get());
            glClear(GL_COLOR_BUFFER_BIT);
            EglContext::currentContext()->popFramebuffer();
            renderInfo.textures.push_back(std::move(texture));
            renderInfo.framebuffers.push_back(std::move(framebuffer));
        }
    }

    const Region dirtyRegion = viewport.mapFromDeviceCoordinatesContained(deviceRegion) & backgroundRect;
    for (const Rect &dirtyRect : dirtyRegion.rects()) {
        renderInfo.framebuffers[0]->blitFromRenderTarget(renderTarget, viewport, dirtyRect, dirtyRect.translated(-backgroundRect.topLeft()));
    }

    GLVertexBuffer *vbo = GLVertexBuffer::streamingBuffer();
    if (!upload(vbo, effectiveShape, backgroundRect, scaledBackgroundRect, true)) {
        qCWarning(AGTERM_GLASS) << "Failed to map vertex buffer";
        return;
    }
    vbo->bindArrays();

    QMatrix4x4 offscreenProjection;
    offscreenProjection.ortho(QRectF(0.0, 0.0, backgroundRect.width(), backgroundRect.height()));
    if (iterations > 0) {
        ShaderManager::instance()->pushShader(m_downsamplePass.shader.get());
        m_downsamplePass.shader->setUniform(m_downsamplePass.mvpMatrix, offscreenProjection);
        m_downsamplePass.shader->setUniform(m_downsamplePass.offset, offset);
        for (size_t i = 1; i < renderInfo.framebuffers.size(); ++i) {
            const auto &read = renderInfo.framebuffers[i - 1];
            const auto &draw = renderInfo.framebuffers[i];
            m_downsamplePass.shader->setUniform(m_downsamplePass.halfpixel, QVector2D(0.5 / read->colorAttachment()->width(), 0.5 / read->colorAttachment()->height()));
            read->colorAttachment()->bind();
            GLFramebuffer::pushFramebuffer(draw.get());
            vbo->draw(GL_TRIANGLES, 0, 6);
        }
        ShaderManager::instance()->popShader();

        ShaderManager::instance()->pushShader(m_upsamplePass.shader.get());
        m_upsamplePass.shader->setUniform(m_upsamplePass.mvpMatrix, offscreenProjection);
        m_upsamplePass.shader->setUniform(m_upsamplePass.offset, offset);
        for (size_t i = renderInfo.framebuffers.size() - 1; i > 1; --i) {
            GLFramebuffer::popFramebuffer();
            const auto &read = renderInfo.framebuffers[i];
            m_upsamplePass.shader->setUniform(m_upsamplePass.halfpixel, QVector2D(0.5 / read->colorAttachment()->width(), 0.5 / read->colorAttachment()->height()));
            read->colorAttachment()->bind();
            vbo->draw(GL_TRIANGLES, 0, 6);
        }
        ShaderManager::instance()->popShader();
        GLFramebuffer::popFramebuffer();
    }

    // onto the screen through the glass: the last upsample (or the clear background) seen through the bevel
    const auto &read = renderInfo.framebuffers[iterations > 0 ? 1 : 0];
    const RectF nativeBox = RectF(w->contentsRect().translated(w->pos())).scaled(viewport.scale()).rounded().translated(-scaledBackgroundRect.topLeft());
    const BorderRadius cornerRadius = w->window()->borderRadius().scaled(viewport.scale()).rounded();
    QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
    projectionMatrix.translate(scaledBackgroundRect.x(), scaledBackgroundRect.y());

    ShaderManager::instance()->pushShader(m_glassPass.shader.get());
    m_glassPass.shader->setUniform(m_glassPass.mvpMatrix, projectionMatrix);
    m_glassPass.shader->setUniform(m_glassPass.halfpixel, QVector2D(0.5 / read->colorAttachment()->width(), 0.5 / read->colorAttachment()->height()));
    m_glassPass.shader->setUniform(m_glassPass.offset, offset);
    m_glassPass.shader->setUniform(m_glassPass.box, QVector4D(nativeBox.center().x(), nativeBox.center().y(), nativeBox.width() * 0.5, nativeBox.height() * 0.5));
    m_glassPass.shader->setUniform(m_glassPass.cornerRadius, cornerRadius.toVector());
    m_glassPass.shader->setUniform(m_glassPass.opacity, float(opacity * opacity));
    m_glassPass.shader->setUniform(m_glassPass.refraction, float(glass.look.refraction * (s_bevel + s_reach) * viewport.scale()));
    // past the screen's edge nothing was captured: samples stay on the part of the background that is on screen
    const RectF onScreen = RectF(backgroundRect).intersected(viewport.renderRect());
    m_glassPass.shader->setUniform(m_glassPass.valid, QVector4D((onScreen.left() - backgroundRect.x()) / backgroundRect.width(),
                                                                1.0 - (onScreen.bottom() - backgroundRect.y()) / backgroundRect.height(),
                                                                (onScreen.right() - backgroundRect.x()) / backgroundRect.width(),
                                                                1.0 - (onScreen.top() - backgroundRect.y()) / backgroundRect.height()));
    m_glassPass.shader->setUniform(m_glassPass.edge, float(s_bevel * viewport.scale()));
    m_glassPass.shader->setUniform(m_glassPass.texSize, QVector2D(scaledBackgroundRect.width(), scaledBackgroundRect.height()));
    read->colorAttachment()->bind();
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    vbo->draw(GL_TRIANGLES, 6, effectiveShape.size() * 6);
    glDisable(GL_BLEND);
    ShaderManager::instance()->popShader();
    vbo->unbindArrays();

    glass.shape = effectiveShape;
    glass.background = backgroundRect;
    glass.scaledBackground = scaledBackgroundRect;
}

void GlassEffect::rim(const RenderViewport &viewport, EffectWindow *w, WindowPaintData &data)
{
    auto it = m_windows.find(w);
    if (it == m_windows.end() || it->second.shape.isEmpty() || it->second.look.refraction <= 0) {
        return;
    }
    GlassWindowData &glass = it->second;
    GLVertexBuffer *vbo = GLVertexBuffer::streamingBuffer();
    if (!upload(vbo, glass.shape, glass.background, glass.scaledBackground, false)) {
        return;
    }
    vbo->bindArrays();
    const RectF nativeBox = RectF(w->contentsRect().translated(w->pos())).scaled(viewport.scale()).rounded().translated(-glass.scaledBackground.topLeft());
    const BorderRadius cornerRadius = w->window()->borderRadius().scaled(viewport.scale()).rounded();
    QMatrix4x4 projectionMatrix = viewport.projectionMatrix();
    projectionMatrix.translate(glass.scaledBackground.x(), glass.scaledBackground.y());

    ShaderManager::instance()->pushShader(m_rimPass.shader.get());
    m_rimPass.shader->setUniform(m_rimPass.mvpMatrix, projectionMatrix);
    m_rimPass.shader->setUniform(m_rimPass.box, QVector4D(nativeBox.center().x(), nativeBox.center().y(), nativeBox.width() * 0.5, nativeBox.height() * 0.5));
    m_rimPass.shader->setUniform(m_rimPass.cornerRadius, cornerRadius.toVector());
    m_rimPass.shader->setUniform(m_rimPass.opacity, float(w->opacity() * data.opacity() * std::min(1.0, 0.4 + glass.look.refraction)));
    m_rimPass.shader->setUniform(m_rimPass.edge, float(s_hairline * viewport.scale()));
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    vbo->draw(GL_TRIANGLES, 0, glass.shape.size() * 6);
    glDisable(GL_BLEND);
    ShaderManager::instance()->popShader();
    vbo->unbindArrays();
}

} // namespace KWin

#include "moc_glass.cpp"
