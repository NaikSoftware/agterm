#pragma once

#include "control.h"

#include <QHash>
#include <QMainWindow>
#include <QPointer>
#include <QSet>
#include <QTimer>

class QKeyEvent;
class QLabel;
class QSplitter;
class QStackedWidget;
class QToolButton;
class QTreeWidget;
class SidebarDelegate;
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

protected:
    void closeEvent(QCloseEvent *event) override;
    void showEvent(QShowEvent *event) override;
    void changeEvent(QEvent *event) override;
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void createActions();
    void applyTheme();
    void updateHeader();
    void createTerminal(const QString &id);
    void rebuildSidebar();
    void showSelected();
    void sidebarMenu(const QPoint &pos);
    void newSession(const QString &workspaceId);
    void newWorkspace();
    void closeSession(const QString &id);
    void renameSession(const QString &id);
    void renameWorkspace(const QString &id);
    void deleteWorkspace(const QString &id);
    void go(const QString &direction);
    void profileDialog(const char *slot);
    void notify(const QString &id, const QString &status);
    TerminalInterface *terminal(const QString &id) const;
    QString liveCwd(const QString &id) const;
    void prime(QWidget *page);
    QObject *konsoleSession(const QString &id);

    Store &m_store;
    QString m_statePath;
    QSplitter *m_split;
    QWidget *m_sidebar;
    QTreeWidget *m_tree;
    SidebarDelegate *m_delegate;
    QToolButton *m_menuButton;
    QWidget *m_footer;
    QLabel *m_socketDot, *m_socketText;
    QList<QLabel *> m_footerLabels;
    QWidget *m_header = nullptr; // null until the constructor has built the chrome
    QLabel *m_crumbWs, *m_crumbSep, *m_crumbName, *m_statusChip, *m_cwdLabel, *m_procChip;
    QStackedWidget *m_stack;
    QWidget *m_empty;
    QTimer m_spinTimer, m_headerTimer;
    bool m_socketOk = false;
    QString m_socketError;
    QHash<QString, KParts::ReadOnlyPart *> m_parts;
    QHash<QString, QPointer<QObject>> m_sessions;
    QSet<QString> m_collapsed;
    QTimer m_saveTimer;
    bool m_quitting = false;
    bool m_rebuilding = false;
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
