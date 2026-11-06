#include "smoothwheel.h"

#include <QApplication>
#include <QWheelEvent>
#include <QWidget>
#include <algorithm>
#include <cmath>

SmoothWheel::SmoothWheel(QObject *parent)
    : QObject(parent)
{
    m_frame.setInterval(16);
    connect(&m_frame, &QTimer::timeout, this, &SmoothWheel::tick);
}

double SmoothWheel::factor(double msPerNotch)
{
    // linear from 1.5 at 120 ms per notch (a slow, deliberate click) to 6 at 20 ms (a flick)
    const double t = std::clamp((120.0 - msPerNotch) / 100.0, 0.0, 1.0);
    return 1.5 + t * 4.5;
}

int SmoothWheel::chunk(int pending, int unit)
{
    const int size = std::max(unit, int(std::abs(pending) * 0.35) / unit * unit);
    return pending > 0 ? std::min(size, pending) : std::max(-size, pending);
}

bool SmoothWheel::eventFilter(QObject *watched, QEvent *event)
{
    if (m_sending || event->type() != QEvent::Wheel || !watched->inherits("Konsole::TerminalDisplay"))
        return false;
    auto *wheel = static_cast<QWheelEvent *>(event);
    const int dy = wheel->angleDelta().y();
    // a touchpad scrolls in phases with pixel deltas and is smooth already; modifiers keep Konsole's own meaning
    if (dy == 0 || wheel->phase() != Qt::NoScrollPhase || !wheel->pixelDelta().isNull() || wheel->modifiers() != Qt::NoModifier)
        return false;

    auto *display = static_cast<QWidget *>(watched);
    const bool sameRun = m_target == display && m_last.isValid() && (m_pending == 0 || (m_pending > 0) == (dy > 0));
    if (!sameRun || m_last.elapsed() > 400) { // a pause starts a fresh, slow run
        if (!sameRun)
            m_pending = 0;
        m_carry = 0;
        m_msPerNotch = 200;
        // Konsole shows an arrow while the program tracks the mouse (TerminalDisplay::resetCursor); it then sends one
        // event per 120 units, so whole notches go out, else 40 units, one line of scrollback or one arrow key
        m_unit = display->cursor().shape() == Qt::ArrowCursor ? 120 : 40;
    } else {
        // high-resolution wheels send fractions of a notch, so time is measured per whole notch, smoothed
        const double perNotch = double(m_last.elapsed()) * 120.0 / std::abs(dy);
        m_msPerNotch = 0.4 * m_msPerNotch + 0.6 * perNotch;
    }
    m_target = display;
    m_inverted = wheel->inverted();
    m_at = wheel->position();
    m_last.start();
    m_carry += dy * factor(m_msPerNotch);
    const int whole = int(m_carry / m_unit) * m_unit; // only whole units, so every step moves something
    m_carry -= whole;
    m_pending += whole;
    if (!m_frame.isActive()) {
        tick(); // the first line moves now, not a frame later
        m_frame.start();
    }
    return true;
}

void SmoothWheel::tick()
{
    if (!m_target || m_pending == 0) {
        m_pending = 0;
        m_frame.stop();
        return;
    }
    const int step = chunk(m_pending, m_unit);
    m_pending -= step;
    QWheelEvent wheel(m_at, m_target->mapToGlobal(m_at), {}, QPoint(0, step), Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, m_inverted);
    m_sending = true;
    QApplication::sendEvent(m_target, &wheel);
    m_sending = false;
}
