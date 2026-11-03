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
    // op inc | dec | reset on pane main | right; records the resulting size on the session
    virtual bool font(const QString &sessionId, const QString &pane, const QString &op, QString *error)
    {
        Q_UNUSED(sessionId);
        Q_UNUSED(pane);
        Q_UNUSED(op);
        *error = QStringLiteral("no terminals");
        return false;
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

// One request object ({cmd, target, args}) in, one response ({ok, result | error}) out.
QJsonObject dispatch(Store &store, Terminals &terminals, const QJsonObject &request);
