#pragma once

#include <QHash>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>

// keymap.conf and hooks.conf live here: an explicit directory setting, else <state dir>/config while
// AGTERM_STATE_DIR is set (test isolation, as master), else ~/.config/agterm-qt.
QString configDirectory(const QString &setting, const QString &stateDirEnv, const QString &home);

struct KeymapDiagnostic {
    int line = 0;
    QString message;
};

struct CustomCommand {
    QString name;
    QString raw;       // the chord token as typed ("" for palette-only)
    QStringList keys;  // each alternative as a portable QKeySequence string ("Ctrl+A, G")
    QString command;   // the shell line, tokens unexpanded
    bool repeat = false, errorHud = false;
    QString errorPosition = QStringLiteral("center"), errorPane;
    int line = 0;
};

struct Keymap {
    QMap<QString, QStringList> bindings; // every available built-in -> its keys after map lines and collisions
    QMap<QString, QString> raw;          // built-ins a map line moved off their default -> the token as typed
    QList<CustomCommand> commands;
    QList<KeymapDiagnostic> diagnostics;
};

// Every BuiltinAction raw name of master, in its order; the ones this app lacks are refused by name.
const QStringList &masterBuiltinActions();
// One kitty-style token ("ctrl+a>g|cmd+t") as portable QKeySequence strings; "" with *error on a bad token.
// macOS words map as the README table: cmd alone -> Ctrl+Shift, cmd with any other modifier -> Ctrl+Alt+Shift, opt -> Alt.
QStringList parseChordToken(const QString &token, QString *error);
// defaults: each available built-in with its shipped keys. A map line replaces an action's keys; a key bound
// twice keeps its first owner and the later alternative drops with a diagnostic.
Keymap parseKeymap(const QString &text, const QMap<QString, QStringList> &defaults);
QString starterKeymap(const QMap<QString, QStringList> &defaults);

// {AGT_X} tokens replaced raw from ctx (missing keys expand to "")
QString expandTokens(QString command, const QHash<QString, QString> &ctx);
const QStringList &commandTokens();

// hooks.conf: `on <kind> <shell...>`
struct HookLine {
    QString kind, command;
    int line = 0;
};
const QStringList &eventKinds(); // master's ControlEventKind raw values
QList<HookLine> parseHooks(const QString &text, QList<KeymapDiagnostic> *diagnostics);
QString starterHooks();
