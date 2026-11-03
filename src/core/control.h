#pragma once

#include <QJsonObject>
#include <QString>

class Store;

// What the dispatcher needs from live terminals; the app implements it over Konsole parts.
class Terminals
{
public:
    virtual ~Terminals() = default;
    virtual bool type(const QString &sessionId, const QString &text, QString *error) = 0;
    virtual QString text(const QString &sessionId, QString *error) = 0;
    virtual QJsonObject info(const QString &sessionId) = 0; // live process fields merged into session.info
    virtual bool quick(const QString &mode, QString *error) // on | off | toggle the app-wide quick terminal
    {
        Q_UNUSED(mode);
        *error = QStringLiteral("no quick terminal");
        return false;
    }
    virtual bool quickVisible() const { return false; }
    // mode show | hide | toggle, or "" with width > 0 to resize only
    virtual bool filePanel(const QString &mode, int width, QString *error)
    {
        Q_UNUSED(mode);
        Q_UNUSED(width);
        *error = QStringLiteral("no file panel");
        return false;
    }
    virtual QJsonObject chromeState() const { return {}; } // chrome read-back merged into `tree`
};

// One request object ({cmd, target, args}) in, one response ({ok, result | error}) out.
QJsonObject dispatch(Store &store, Terminals &terminals, const QJsonObject &request);
