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
class QStackedLayout;
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
    bool quick(const QString &mode, QString *error) override;
    bool quickVisible() const override;

protected:
    void closeEvent(QCloseEvent *event) override;
    void showEvent(QShowEvent *event) override;
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    QAction *action(const QString &name, const QString &text, const QString &icon, const QKeySequence &key, std::function<void()> slot);
    void createMenus();
    void createTerminal(const QString &id);
    KParts::ReadOnlyPart *spawnPart(const QString &id, const QString &pane, const QString &cwd, const QString &command, QWidget *parent);
    void applyLayout(const QString &id);
    void paneExited(const QString &id, KParts::ReadOnlyPart *part);
    void swapPanes(const QString &id);
    void focusPane(bool right);
    void toggleZoom();
    void showQuick(bool on, bool pinned);
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
    struct Panes {
        QWidget *view = nullptr;          // the session's page in m_stack
        QStackedLayout *layers = nullptr; // split view, with the scratch above it when shown
        QSplitter *split = nullptr;
        KParts::ReadOnlyPart *main = nullptr, *right = nullptr, *scratch = nullptr;
    };
    QHash<QString, Panes> m_panes;
    QWidget *m_strip = nullptr;
    QWidget *m_quick = nullptr;
    KParts::ReadOnlyPart *m_quickPart = nullptr;
    bool m_quickPinned = false; // opened over the socket: stays put on click-away
    bool m_zoomed = false;
    QString m_shownId;
    bool m_zoomRestoreSidebar = true, m_zoomRestoreMenu = true;
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
