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
};

// One request object ({cmd, target, args}) in, one response ({ok, result | error}) out.
QJsonObject dispatch(Store &store, Terminals &terminals, const QJsonObject &request);
