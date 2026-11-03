#pragma once

#include "control.h"

#include <QDateTime>
#include <QHash>
#include <QMainWindow>
#include <QPointer>
#include <QTimer>

class QKeyEvent;
class QLabel;
class QMenu;
class QSplitter;
class QStackedWidget;
class QToolButton;
class Sidebar;
class Store;
class TerminalInterface;
namespace KParts { class ReadOnlyPart; }

class MainWindow : public QMainWindow, public Terminals
{
    Q_OBJECT
public:
    MainWindow(Store &store, const QString &statePath);
    ~MainWindow() override;
    void restore(const QJsonObject &window); // one terminal per stored session, plus saved geometry

    bool type(const QString &sessionId, const QString &text, QString *error) override;
    QString text(const QString &sessionId, QString *error) override;
    QJsonObject info(const QString &sessionId) override;

    void save();
    bool isOwnShortcut(QKeyEvent *event) const;
    void setSocketStatus(bool ok, const QString &error);
    QStringList availableLaunchers() const { return m_launchers; }

protected:
    void closeEvent(QCloseEvent *event) override;
    void showEvent(QShowEvent *event) override;
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    QAction *action(const QString &name, const QString &text, const QString &icon, const QKeySequence &key, std::function<void()> slot);
    void createMenus();
    void createTerminal(const QString &id);
    void showSelected();
    void sidebarMenu(const QPoint &pos);
    void launcherMenu(const QString &workspaceId, const QPoint &globalPos);
    void launch(const QString &launcherId, const QString &workspaceId);
    QString currentWorkspace();
    void newSession(const QString &workspaceId);
    void newWorkspace();
    void openDirectory();
    void closeSessions(const QStringList &ids);
    void deleteWorkspace(const QString &id);
    void fillMoveMenu(QMenu *menu, const QStringList &ids);
    void go(const QString &direction);
    void profileDialog(const char *slot);
    void showSettings();
    void sampleAgents();
    void detectLaunchers();
    TerminalInterface *terminal(const QString &id) const;
    QString liveCwd(const QString &id) const;
    void prime(QWidget *page);
    QObject *konsoleSession(const QString &id);

    Store &m_store;
    QString m_statePath;
    QSplitter *m_split;
    QWidget *m_sidebarPanel;
    Sidebar *m_tree;
    QToolButton *m_flagButton;
    QAction *m_sidebarAction;
    QLabel *m_title;
    QStackedWidget *m_stack;
    QWidget *m_empty;
    QHash<QString, QAction *> m_actions;
    QHash<QString, KParts::ReadOnlyPart *> m_parts;
    QHash<QString, QPointer<QObject>> m_sessions;
    QStringList m_launchers{QStringLiteral("terminal")};
    QDateTime m_launchersAt;
    QTimer m_saveTimer, m_agentTimer;
    bool m_quitting = false;
};

// Receives the Konsole part's string-only signals for one session.
class PartBridge : public QObject
{
    Q_OBJECT
public:
    PartBridge(MainWindow *window, Store &store, const QString &id, QObject *parent);
public Q_SLOTS:
    void currentDirectoryChanged(const QString &dir);
    void overrideShortcut(QKeyEvent *event, bool &override);

private:
    MainWindow *m_window;
    Store &m_store;
    QString m_id;
};
