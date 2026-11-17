#pragma once

#include "keymap.h"

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QTimer>

class QProcess;
class Store;

// master's control events from the store's signals: {seq, ts, kind, workspace, session, payload}
class EventSource : public QObject
{
    Q_OBJECT
public:
    explicit EventSource(Store &store, QObject *parent = nullptr);
    void emitEvent(const QString &kind, const QString &workspace = {}, const QString &session = {}, const QJsonObject &payload = {});
    QString window; // the window id stamped on its events
    static const QStringList kinds;
    // events.read over the app-wide ring: without a cursor, an empty batch anchored at now; "" error when valid
    static QJsonObject read(const QJsonObject &args, QString *error);

Q_SIGNALS:
    void event(const QJsonObject &event);

private:
    void snapshot();
    Store &m_store;
    QHash<QString, QString> m_status, m_workspaceOf, m_names;
    QHash<QString, bool> m_splitShown;
    QString m_selected;
    QTimer m_treeTimer; // tree.changed coalesces over 100 ms, as master
};

// hooks.conf: one /bin/sh child per line at a time, the event as JSON on stdin, later events queued (256 max).
class HookRunner : public QObject
{
    Q_OBJECT
public:
    explicit HookRunner(QObject *parent = nullptr);
    ~HookRunner() override;
    int load(const QString &path); // diagnostics count; an unchanged line keeps its child, queue and counters
    void fire(const QJsonObject &event);
    QJsonObject list() const; // the hooks.list read-back
    QString path;
    QList<KeymapDiagnostic> diagnostics;
    QString socket, pathPrefix; // AGT_SOCKET, and a directory put first on PATH so a bare agtermctl resolves

Q_SIGNALS:
    void failed(const QString &hook, const QString &message); // once per hook until it next succeeds or a reload

private:
    struct Hook {
        HookLine line;
        QProcess *proc = nullptr;
        QDateTime started;
        QList<QJsonObject> queue;
        quint64 dropped = 0;
        QString lastFailure;
        bool retired = false, reported = false;
    };
    void start(Hook *h);
    void finished(Hook *h, const QString &failure);
    QList<Hook *> m_hooks; // live in file order, then retired ones still running
};
