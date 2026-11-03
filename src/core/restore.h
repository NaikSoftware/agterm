#pragma once

#include <QString>
#include <QStringList>

// Re-run commands restore (master's CommandRestore): what a pane runs at quit is typed into its shell next launch.
namespace Restore {
// The foreground group leader's argv as worth re-running; empty for an idle shell (a shell name with only - flags).
// A leading '-' (login shell) is dropped from argv[0].
QStringList captured(QStringList argv, const QString &userShell);
// Refuses an empty argv, a denylisted basename, and any argument with C0/DEL or an invalid-UTF-8 replacement character.
bool shouldRestore(const QStringList &argv, const QStringList &denylist);
QString shellQuoted(const QStringList &argv); // POSIX single-quoted, space-joined
QStringList parseDenylist(const QString &text); // one basename per line; blanks and # comments ignored
extern const char *const starterDenylist;
// the session.restore pin's rules; "" when valid
QString pinError(const QString &command);
}
