#pragma once

#include <QElapsedTimer>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QTimer>

class QWidget;

// Konsole moves a fixed 3 lines per wheel notch (one mouse event when the program tracks the mouse, as Claude Code
// does), in one jump. This app-wide filter takes plain mouse-wheel notches on a Konsole::TerminalDisplay, scales them
// up while the wheel spins fast, and replays them a line at a time over the next frames. Touchpads and modified
// wheels (Ctrl zoom) pass through untouched.
class SmoothWheel : public QObject
{
public:
    explicit SmoothWheel(QObject *parent = nullptr);

    // multiplier for a notch arriving msPerNotch after the previous one: 1.5 when slow, up to 6 on a fast spin
    static double factor(double msPerNotch);
    // the part of pending (wheel angle units, 120 a notch) to send this frame: an eased share, at least one line (40)
    static int chunk(int pending);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void tick();

    QPointer<QWidget> m_target; // one mouse, so one display scrolls at a time
    int m_pending = 0;
    double m_msPerNotch = 200;
    QPointF m_at; // where the wheel turned: a mouse-tracking program gets that cell
    QElapsedTimer m_last;
    QTimer m_frame;
    bool m_inverted = false; // natural scrolling, passed on as it came
    bool m_sending = false;
};
