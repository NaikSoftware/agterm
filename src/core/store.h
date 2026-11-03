#pragma once

#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>

struct Session {
    QString id;
    QString name; // pinned by a rename; empty = derived from the cwd
    QString cwd;
    QString status = QStringLiteral("idle"); // idle | active | completed | blocked; never persisted
    bool blink = false;
    bool autoReset = false; // a completed status clears once the session is viewed
    bool flagged = false;
    QString title;   // live terminal title, spinner glyphs stripped; not persisted
    QString agent;   // launcher id of the coding agent in the foreground, "" for none; not persisted
    QString command; // run instead of a shell at creation, not persisted
    // one session, up to two terminals: the split pane is a second shell sharing the sidebar row
    bool hasSplit = false;
    bool splitVisible = false;
    QString splitAxis = QStringLiteral("vertical"); // vertical = side by side, horizontal = top and bottom
    double splitRatio = 0.5;
    bool scratchVisible = false; // the scratch shell covers the session; not persisted, like agterm's

    QString displayName() const;
};

struct Workspace {
    QString id;
    QString name;
    QString folder; // last directory one of its sessions reported; where new sessions open
    QList<Session> sessions;
};

struct Settings {
    QString newSessionDirectory = QStringLiteral("workspace"); // home | workspace | custom
    QString newSessionCustomDirectory;
    QString newSessionPlacement = QStringLiteral("end"); // end | afterCurrent
    QString statusReset = QStringLiteral("firstKey");    // firstKey | enter | never
    QString lastLauncher = QStringLiteral("terminal");
    bool confirmCloseSession = false;
};

// The workspace -> session tree. Owns no terminals: the window reacts to its signals.
class Store : public QObject
{
    Q_OBJECT
public:
    enum class Key { Plain, Submit, Interrupt };
    static const QStringList statuses;

    QList<Workspace> workspaces;
    QString selected;
    QStringList recent; // session ids, most recently selected first
    Settings settings;

    Session *session(const QString &id);
    Workspace *workspace(const QString &id);
    Workspace *workspaceOf(const QString &sessionId);
    QList<Session *> allSessions();

    // target: "" or "active" -> current; else exact id, unique id prefix, or unique exact name.
    QString resolveSession(const QString &target, QString *error);
    QString resolveWorkspace(const QString &target, QString *error);
    QString workspaceRemembering(const QString &folder) const;
    QString newSessionCwd(const QString &workspaceId, const QString &currentCwd) const;

    QString addWorkspace(const QString &name);
    // index -1 follows settings.newSessionPlacement
    QString addSession(const QString &workspaceId, const QString &name, const QString &cwd, const QString &command = {}, int index = -1);
    QString duplicateSession(const QString &id, const QString &cwd);
    void removeSession(const QString &id);
    void removeWorkspace(const QString &id);
    void renameSession(const QString &id, const QString &name); // "" reverts to the cwd-derived name
    void renameWorkspace(const QString &id, const QString &name);
    bool moveSession(const QString &id, const QString &workspaceId, int index); // index -1 = end
    bool moveWorkspace(const QString &id, int index);
    void select(const QString &id);
    bool setStatus(const QString &id, const QString &status, bool autoReset = false, bool blink = false);
    void setFlag(const QString &id, bool flagged);
    void setCwd(const QString &id, const QString &cwd);
    void setTitle(const QString &id, const QString &title);
    void setAgent(const QString &id, const QString &agent);
    void setSettings(const Settings &s);
    void keyPressed(const QString &id, Key key);
    // ⌘D / ⌘⇧D: create, transpose (other axis), or hide (same axis); a shown scratch is hidden instead
    void toggleSplit(const QString &id, const QString &axis);
    void setSplit(const QString &id, bool hasSplit, bool visible, const QString &axis);
    void setScratch(const QString &id, bool visible);
    void requestSwap(const QString &id) { Q_EMIT swapRequested(id); }
    QString go(const QString &direction, QString *error); // next | prev | first | last | next-attention | prev-attention

    QJsonObject toJson() const;
    void fromJson(const QJsonObject &o);

    static QString stripTitleSpinner(const QString &title);

Q_SIGNALS:
    void changed();
    void sessionAdded(const QString &id);
    void sessionRemoved(const QString &id);
    void selectionChanged(const QString &id);
    void statusChanged(const QString &id, const QString &status);
    void titleChanged(const QString &id);
    void paneLayoutChanged(const QString &id);
    void swapRequested(const QString &id);

private:
    static QString newId();
    int indexIn(const Workspace &w, const QString &sessionId) const;
};
