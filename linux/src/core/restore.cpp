#include "restore.h"

#include <QFileInfo>

namespace Restore {

const char *const starterDenylist = R"(# restore-denylist.conf: programs NOT to re-run in rerun restore mode. One command name per line,
# matched on the command's basename. Blank lines and lines
# starting with # are ignored. Read at launch; edits take effect on the next launch.
#
# Terminal multiplexers just start a fresh, empty session when re-run (your old session is gone),
# so they are listed by default - delete a line to let it restore:
tmux
screen
zellij
#
# Add anything else you would rather start fresh, e.g. an editor or pager:
# vim
# less
)";

QStringList captured(QStringList argv, const QString &userShell)
{
    if (argv.isEmpty())
        return {};
    if (argv[0].startsWith(QLatin1Char('-')))
        argv[0].remove(0, 1);
    static const QStringList shells{"zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh"};
    const QString base = QFileInfo(argv[0]).fileName();
    const bool shell = shells.contains(base) || (!userShell.isEmpty() && base == QFileInfo(userShell).fileName());
    bool flagsOnly = true;
    for (int i = 1; i < argv.size(); ++i)
        flagsOnly &= argv[i].startsWith(QLatin1Char('-'));
    return shell && flagsOnly ? QStringList() : argv;
}

bool shouldRestore(const QStringList &argv, const QStringList &denylist)
{
    if (argv.isEmpty() || denylist.contains(QFileInfo(argv[0]).fileName()))
        return false;
    for (const QString &a : argv)
        for (QChar c : a)
            if (c.unicode() < 0x20 || c.unicode() == 0x7f || c == QChar::ReplacementCharacter)
                return false;
    return true;
}

QString shellQuoted(const QStringList &argv)
{
    QStringList out;
    for (QString a : argv)
        out << QLatin1Char('\'') + a.replace(QLatin1Char('\''), QStringLiteral("'\\''")) + QLatin1Char('\'');
    return out.join(QLatin1Char(' '));
}

QStringList parseDenylist(const QString &text)
{
    QStringList out;
    for (const QString &line : text.split(QLatin1Char('\n'))) {
        const QString t = line.trimmed();
        if (!t.isEmpty() && !t.startsWith(QLatin1Char('#')))
            out << t;
    }
    return out;
}

QString pinError(const QString &command)
{
    if (command.isEmpty())
        return QStringLiteral("session.restore set requires a command");
    for (QChar c : command)
        if (c.unicode() < 0x20 || c.unicode() == 0x7f)
            return QStringLiteral("command must not contain control characters");
    if (command.toUtf8().size() > 1024)
        return QStringLiteral("command too long (max 1024 bytes)");
    return {};
}

} // namespace Restore
