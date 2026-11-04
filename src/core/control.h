#pragma once

#include <QJsonObject>
#include <QString>

class Store;

// what one pane of a Duplicate as Companion starts: a shell in cwd, or another copy of its program
struct PanePlan {
    QString cwd, command; // command "" = a plain shell
};

// What the dispatcher needs from live terminals; the app implements it over Konsole parts.
class Terminals
{
public:
    virtual ~Terminals() = default;
    virtual bool type(const QString &sessionId, const QString &text, QString *error) = 0;
    virtual QString text(const QString &sessionId, QString *error) = 0;
    virtual QJsonObject info(const QString &sessionId) = 0; // live process fields merged into session.info
    // mode show | hide | toggle, or "" with width > 0 to resize only
    virtual bool filePanel(const QString &mode, int width, QString *error)
    {
        Q_UNUSED(mode);
        Q_UNUSED(width);
        *error = QStringLiteral("no file panel");
        return false;
    }
    virtual QJsonObject chromeState() const { return {}; } // chrome read-back merged into `tree`
    virtual QJsonObject sessionExtras(const QString &sessionId) const // overlay/HUD read-back merged into each session node
    {
        Q_UNUSED(sessionId);
        return {};
    }
    // op inc | dec | reset on pane main | right; records the resulting size on the session
    virtual bool font(const QString &sessionId, const QString &pane, const QString &op, QString *error)
    {
        Q_UNUSED(sessionId);
        Q_UNUSED(pane);
        Q_UNUSED(op);
        *error = QStringLiteral("no terminals");
        return false;
    }
    // keymap.* hooks.* theme.*: config the app owns; sessionId is resolved for keymap.run only
    virtual bool appCommand(const QString &cmd, const QString &sessionId, const QJsonObject &args, QJsonObject *result, QString *error)
    {
        Q_UNUSED(sessionId);
        Q_UNUSED(args);
        Q_UNUSED(result);
        *error = QStringLiteral("unknown command '%1'").arg(cmd);
        return false;
    }
    // the foreground process group leader's argv in pane main | right; empty when it cannot be read
    virtual QStringList foregroundArgv(const QString &sessionId, const QString &pane)
    {
        Q_UNUSED(sessionId);
        Q_UNUSED(pane);
        return {};
    }
    virtual bool saveNow(QString *error) // a checked save, for commands that ack only what reached disk
    {
        Q_UNUSED(error);
        return true;
    }
    // pane main | right; false with the reason when the pane's program cannot be copied
    virtual bool panePlan(const QString &sessionId, const QString &pane, PanePlan *out, QString *error)
    {
        Q_UNUSED(sessionId);
        Q_UNUSED(pane);
        Q_UNUSED(out);
        *error = QStringLiteral("no terminals");
        return false;
    }
};

// A companion copying the session's split layout and each pane's program; plans every pane before creating
// anything, so one refused pane leaves the tree as it was. "" with *error set on refusal.
QString duplicateAsCompanion(Store &store, Terminals &terminals, const QString &id, QString *error);

// session.overlay.* / session.hud.*: master's argument rules; canonicalizes pane (left|right) and position in place.
// "" when valid.
QString overlayArgsError(const QString &cmd, QJsonObject *args);

// Fills each session's captured foreground commands (main, and the split when shown) for re-run restore;
// returns how many slots hold a command.
int captureForeground(Store &store, Terminals &terminals);

// Dashboard members as "<session>:left|right" in grid order: a bare id expands to its panes, duplicates and unknown
// ids drop, at most 9 cells. *notes says what was dropped; "" with *error on a malformed request.
QStringList dashboardCells(Store &store, const QStringList &targets, bool mru, QString *notes, QString *error);
// master's grid: cols = ceil(sqrt(n)), rows = ceil(n / cols); and the auto font factor for that shape
std::pair<int, int> dashboardGrid(int count);
double dashboardFontFactor(int cols, int rows);

// One request object ({cmd, target, args}) in, one response ({ok, result | error}) out.
QJsonObject dispatch(Store &store, Terminals &terminals, const QJsonObject &request);
