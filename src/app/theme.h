#pragma once

#include <QColor>
#include <QPalette>
#include <QString>

// Semantic colours for one palette, so the UI follows the system light/dark scheme.
struct Theme {
    bool dark;
    QColor window, sidebar, text, dim, faint, line, accent, warn, ok, onWarn;

    static Theme from(const QPalette &palette);
    static QColor alpha(QColor c, int a) { return c.setAlpha(a), c; }
    static QString css(const QColor &c) { return c.name(QColor::HexArgb); }

    QColor statusColor(const QString &status) const;
    static QString statusPhrase(const QString &status);
};

QString shortPath(const QString &path); // $HOME -> ~
