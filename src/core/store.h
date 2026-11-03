#pragma once

#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>

struct Session {
    QString id;
    QString name;
    QString cwd;
    QString status = QStringLiteral("idle"); // idle | active | completed | blocked; never persisted
    bool autoReset = false;                  // a completed status clears once the session is viewed
    QString title;                           // live terminal title, not persisted
    QString command;                         // run instead of a shell at creation, not persisted
};

struct Workspace {
    QString id;
    QString name;
    QList<Session> sessions;
};

// The workspace -> session tree. Owns no terminals: the window reacts to its signals.
class Store : public QObject
{
    Q_OBJECT
public:
    static const QStringList statuses;

    QList<Workspace> workspaces;
    QString selected;

    Session *session(const QString &id);
    Workspace *workspace(const QString &id);
    Workspace *workspaceOf(const QString &sessionId);
    QList<Session *> allSessions();

    // target: "" or "active" -> current; else exact id, unique id prefix, or unique exact name.
    QString resolveSession(const QString &target, QString *error);
    QString resolveWorkspace(const QString &target, QString *error);

    QString addWorkspace(const QString &name);
    QString addSession(const QString &workspaceId, const QString &name, const QString &cwd, const QString &command = {});
    void removeSession(const QString &id);
    void removeWorkspace(const QString &id);
    void renameSession(const QString &id, const QString &name);
    void renameWorkspace(const QString &id, const QString &name);
    void select(const QString &id);
    bool setStatus(const QString &id, const QString &status, bool autoReset = false);
    void setCwd(const QString &id, const QString &cwd);
    void setTitle(const QString &id, const QString &title);
    void keyPressed(const QString &id); // blocked/completed glyph means "look at me"; typing is looking
    QString go(const QString &direction, QString *error); // next | prev | next-attention | prev-attention

    QJsonObject toJson() const;
    void fromJson(const QJsonObject &o);

Q_SIGNALS:
    void changed();
    void sessionAdded(const QString &id);
    void sessionRemoved(const QString &id);
    void selectionChanged(const QString &id);
    void statusChanged(const QString &id, const QString &status);

private:
    static QString newId();
};
