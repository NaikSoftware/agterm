#include "theme.h"

#include <KColorScheme>
#include <QDir>

Theme Theme::from(const QPalette &palette)
{
    Theme t;
    t.window = palette.color(QPalette::Window);
    t.dark = t.window.lightnessF() < 0.5;
    t.sidebar = t.dark ? t.window.darker(118) : t.window.lighter(104);
    t.text = palette.color(QPalette::WindowText);
    t.dim = Theme::alpha(t.text, 190);
    t.faint = Theme::alpha(t.text, 140);
    t.line = Theme::alpha(t.text, t.dark ? 34 : 40);
    const KColorScheme scheme(QPalette::Active, KColorScheme::View);
    t.accent = palette.color(QPalette::Highlight);
    t.warn = scheme.foreground(KColorScheme::NeutralText).color();
    t.ok = scheme.foreground(KColorScheme::PositiveText).color();
    t.onWarn = t.dark ? t.sidebar : QColor(Qt::white);
    return t;
}

QColor Theme::statusColor(const QString &status) const
{
    if (status == QLatin1String("active"))
        return accent;
    if (status == QLatin1String("blocked"))
        return warn;
    if (status == QLatin1String("completed"))
        return ok;
    return faint;
}

QString Theme::statusPhrase(const QString &status)
{
    if (status == QLatin1String("active"))
        return QStringLiteral("Working…");
    if (status == QLatin1String("blocked"))
        return QStringLiteral("Needs your input");
    if (status == QLatin1String("completed"))
        return QStringLiteral("Done");
    return QStringLiteral("Idle");
}

QString shortPath(const QString &path)
{
    const QString home = QDir::homePath();
    if (path == home)
        return QStringLiteral("~");
    return path.startsWith(home + QLatin1Char('/')) ? QLatin1Char('~') + path.mid(home.size()) : path;
}
