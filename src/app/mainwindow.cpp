#include "mainwindow.h"

#include "paths.h"
#include "store.h"

#include <KNotification>
#include <KParts/PartLoader>
#include <KParts/ReadOnlyPart>
#include <kde_terminal_interface.h>

#include <QAction>
#include <QApplication>
#include <QCloseEvent>
#include <QDBusConnection>
#include <QDir>
#include <QFileInfo>
#include <QHeaderView>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLabel>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QSaveFile>
#include <QSplitter>
#include <QStackedWidget>
#include <QStatusBar>
#include <QTreeWidget>

namespace {
enum Role { IdRole = Qt::UserRole, KindRole };
enum Kind { WorkspaceKind = 1, SessionKind };

QIcon statusIcon(const QString &status)
{
    if (status == QLatin1String("active"))
        return QIcon::fromTheme(QStringLiteral("media-playback-start"));
    if (status == QLatin1String("blocked"))
        return QIcon::fromTheme(QStringLiteral("dialog-warning"));
    if (status == QLatin1String("completed"))
        return QIcon::fromTheme(QStringLiteral("checkmark"), QIcon::fromTheme(QStringLiteral("dialog-ok")));
    return QIcon::fromTheme(QStringLiteral("utilities-terminal"));
}
} // namespace

PartBridge::PartBridge(MainWindow *window, Store &store, const QString &id, QObject *parent)
    : QObject(parent), m_window(window), m_store(store), m_id(id)
{
}

void PartBridge::currentDirectoryChanged(const QString &dir)
{
    m_store.setCwd(m_id, dir);
}

void PartBridge::overrideShortcut(QKeyEvent *event, bool &override)
{
    // true = the host takes the key; the terminal would otherwise swallow every app shortcut
    if (m_window->isOwnShortcut(event))
        override = true;
}

MainWindow::MainWindow(Store &store, const QString &statePath)
    : m_store(store), m_statePath(statePath)
{
    m_tree = new QTreeWidget;
    m_tree->setHeaderHidden(true);
    m_tree->setRootIsDecorated(true);
    m_tree->setContextMenuPolicy(Qt::CustomContextMenu);
    m_tree->setFocusPolicy(Qt::NoFocus); // keyboard stays in the terminal
    m_stack = new QStackedWidget;
    m_empty = new QLabel(tr("No sessions.\nCtrl+Shift+T opens one."));
    m_empty->setAlignment(Qt::AlignCenter);
    m_stack->addWidget(m_empty);
    m_split = new QSplitter;
    m_split->addWidget(m_tree);
    m_split->addWidget(m_stack);
    m_split->setStretchFactor(1, 1);
    m_split->setSizes({220, 900});
    setCentralWidget(m_split);
    resize(1200, 760);

    createActions();

    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(500);
    connect(&m_saveTimer, &QTimer::timeout, this, &MainWindow::save);

    connect(&m_store, &Store::changed, this, [this] {
        rebuildSidebar();
        m_saveTimer.start();
    });
    connect(&m_store, &Store::sessionAdded, this, &MainWindow::createTerminal);
    connect(&m_store, &Store::sessionRemoved, this, [this](const QString &id) {
        m_sessions.remove(id);
        if (auto *part = m_parts.take(id))
            part->deleteLater(); // closes the pty, which hangs up the shell
    });
    connect(&m_store, &Store::selectionChanged, this, &MainWindow::showSelected);
    connect(&m_store, &Store::statusChanged, this, &MainWindow::notify);
    connect(m_tree, &QTreeWidget::currentItemChanged, this, [this](QTreeWidgetItem *item) {
        if (!m_rebuilding && item && item->data(0, KindRole).toInt() == SessionKind)
            m_store.select(item->data(0, IdRole).toString());
    });
    connect(m_tree, &QTreeWidget::itemCollapsed, this, [this](QTreeWidgetItem *i) { m_collapsed.insert(i->data(0, IdRole).toString()); });
    connect(m_tree, &QTreeWidget::itemExpanded, this, [this](QTreeWidgetItem *i) { m_collapsed.remove(i->data(0, IdRole).toString()); });
    connect(m_tree, &QTreeWidget::customContextMenuRequested, this, &MainWindow::sidebarMenu);
    connect(m_tree, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem *item) {
        const QString id = item->data(0, IdRole).toString();
        item->data(0, KindRole).toInt() == SessionKind ? renameSession(id) : renameWorkspace(id);
    });
    qApp->installEventFilter(this);
}

void MainWindow::createActions()
{
    auto add = [this](QMenu *menu, const QString &text, const QKeySequence &key, const QString &icon, auto slot) {
        auto *a = menu->addAction(QIcon::fromTheme(icon), text);
        a->setShortcut(key);
        connect(a, &QAction::triggered, this, slot);
        addAction(a); // shortcuts work with the menu bar hidden
        return a;
    };
    auto *file = menuBar()->addMenu(tr("&Session"));
    add(file, tr("&New Session"), QKeySequence(QStringLiteral("Ctrl+Shift+T")), QStringLiteral("tab-new"),
        [this] { QString e; newSession(m_store.resolveWorkspace({}, &e)); });
    add(file, tr("New &Workspace…"), QKeySequence(QStringLiteral("Ctrl+Shift+N")), QStringLiteral("folder-new"), &MainWindow::newWorkspace);
    add(file, tr("&Rename Session…"), QKeySequence(QStringLiteral("Ctrl+Shift+R")), QStringLiteral("edit-rename"),
        [this] { renameSession(m_store.selected); });
    add(file, tr("&Close Session"), QKeySequence(QStringLiteral("Ctrl+Shift+W")), QStringLiteral("tab-close"),
        [this] { closeSession(m_store.selected); });
    file->addSeparator();
    add(file, tr("&Quit"), QKeySequence(QStringLiteral("Ctrl+Shift+Q")), QStringLiteral("application-exit"), &QWidget::close);

    auto *view = menuBar()->addMenu(tr("&View"));
    add(view, tr("Next Session"), QKeySequence(QStringLiteral("Ctrl+PgDown")), QStringLiteral("go-down"), [this] { go(QStringLiteral("next")); });
    add(view, tr("Previous Session"), QKeySequence(QStringLiteral("Ctrl+PgUp")), QStringLiteral("go-up"), [this] { go(QStringLiteral("prev")); });
    add(view, tr("Next Session Needing Attention"), QKeySequence(QStringLiteral("Ctrl+Alt+Down")), QStringLiteral("go-down-skip"),
        [this] { go(QStringLiteral("next-attention")); });
    add(view, tr("Previous Session Needing Attention"), QKeySequence(QStringLiteral("Ctrl+Alt+Up")), QStringLiteral("go-up-skip"),
        [this] { go(QStringLiteral("prev-attention")); });
    view->addSeparator();
    add(view, tr("Show &Sidebar"), QKeySequence(QStringLiteral("Ctrl+Shift+B")), QStringLiteral("sidebar-show"),
        [this] { m_tree->setVisible(!m_tree->isVisible()); m_saveTimer.start(); });
    add(view, tr("Show &Menu Bar"), QKeySequence(QStringLiteral("Ctrl+Shift+M")), QStringLiteral("show-menu"),
        [this] { menuBar()->setVisible(!menuBar()->isVisible()); m_saveTimer.start(); });

    auto *settings = menuBar()->addMenu(tr("Se&ttings"));
    add(settings, tr("&Edit Current Profile…"), {}, QStringLiteral("document-edit"), [this] { profileDialog("showEditCurrentProfileDialog"); });
    add(settings, tr("&Manage Profiles…"), {}, QStringLiteral("configure"), [this] { profileDialog("showManageProfilesDialog"); });
}

bool MainWindow::isOwnShortcut(QKeyEvent *event) const
{
    const QKeySequence key(event->keyCombination());
    for (const QAction *a : actions())
        if (!a->shortcut().isEmpty() && a->shortcut().matches(key) == QKeySequence::ExactMatch)
            return true;
    return false;
}

void MainWindow::restore(const QJsonObject &window)
{
    for (auto *s : m_store.allSessions())
        createTerminal(s->id);
    restoreGeometry(QByteArray::fromBase64(window.value("geometry").toString().toLatin1()));
    m_split->restoreState(QByteArray::fromBase64(window.value("splitter").toString().toLatin1()));
    for (const auto &v : window.value("collapsed").toArray())
        m_collapsed.insert(v.toString());
    m_tree->setVisible(window.value("sidebar").toBool(true));
    menuBar()->setVisible(window.value("menubar").toBool(true));
    rebuildSidebar();
    showSelected();
}

void MainWindow::createTerminal(const QString &id)
{
    const Session *s = m_store.session(id);
    auto result = KParts::PartLoader::instantiatePart<KParts::ReadOnlyPart>(KPluginMetaData(QStringLiteral("kf6/parts/konsolepart")), m_stack, this);
    if (!result) {
        statusBar()->showMessage(tr("Cannot load the Konsole part: %1").arg(result.errorString));
        return;
    }
    KParts::ReadOnlyPart *part = result.plugin;
    m_parts.insert(id, part);
    m_stack->addWidget(part->widget());

    auto *bridge = new PartBridge(this, m_store, id, part);
    connect(part, SIGNAL(currentDirectoryChanged(QString)), bridge, SLOT(currentDirectoryChanged(QString)));
    connect(part, SIGNAL(overrideShortcut(QKeyEvent *, bool &)), bridge, SLOT(overrideShortcut(QKeyEvent *, bool &)));
    connect(part, &KParts::Part::setWindowCaption, this, [this, id](const QString &title) {
        m_store.setTitle(id, title);
        if (id == m_store.selected)
            showSelected();
    });
    // the part deletes itself when its shell exits; that ends the session, except during app teardown
    connect(part, &QObject::destroyed, this, [this, id] {
        if (m_quitting)
            return;
        m_parts.remove(id);
        m_store.removeSession(id);
    });

    const QString dir = QFileInfo(s->cwd).isDir() ? s->cwd : QDir::homePath();
    const QString appDir = QCoreApplication::applicationDirPath();
    const QString shell = qEnvironmentVariable("SHELL", QStringLiteral("/bin/bash"));
    QStringList argv{QStringLiteral("/usr/bin/env"),
                     QStringLiteral("-C"),
                     dir,
                     QStringLiteral("AGTERM_SESSION_ID=") + id,
                     QStringLiteral("AGTERM_WORKSPACE_ID=") + m_store.workspaceOf(id)->id,
                     QStringLiteral("AGTERM_SOCKET=") + socketPath(),
                     QStringLiteral("AGTERMCTL=") + appDir + QStringLiteral("/agtermctl"),
                     QStringLiteral("PATH=") + appDir + QLatin1Char(':') + qEnvironmentVariable("PATH"),
                     shell};
    if (!s->command.isEmpty())
        argv << QStringLiteral("-c") << s->command;
    qobject_cast<TerminalInterface *>(part)->startProgram(argv.first(), argv);
    prime(part->widget());
}

TerminalInterface *MainWindow::terminal(const QString &id) const
{
    auto *part = m_parts.value(id);
    return part ? qobject_cast<TerminalInterface *>(part) : nullptr;
}

QString MainWindow::liveCwd(const QString &id) const
{
    // Konsole refreshes its own answer only for the shown pane
    auto *t = terminal(id);
    return t ? QFile::symLinkTarget(QStringLiteral("/proc/%1/cwd").arg(t->terminalProcessId())) : QString();
}

void MainWindow::prime(QWidget *page)
{
    // a never-shown terminal has no screen size, so it would read back empty; one synchronous show sizes it
    if (!isVisible() || page->property("primed").toBool())
        return;
    page->setProperty("primed", true);
    QWidget *current = m_stack->currentWidget();
    m_stack->setCurrentWidget(page);
    m_stack->setCurrentWidget(current);
}

void MainWindow::showEvent(QShowEvent *event)
{
    QMainWindow::showEvent(event);
    for (auto *part : std::as_const(m_parts))
        prime(part->widget());
}

QObject *MainWindow::konsoleSession(const QString &id)
{
    // Konsole::Session is owned by Konsole's session manager, not the part; it registers on the
    // in-process bus as /Sessions/N, and the shell pid ties it to our part.
    if (auto cached = m_sessions.value(id))
        return cached;
    auto *t = terminal(id);
    if (!t)
        return nullptr;
    const int pid = t->terminalProcessId();
    for (int n = 1; n < 4096; ++n) {
        QObject *o = QDBusConnection::sessionBus().objectRegisteredAt(QStringLiteral("/Sessions/%1").arg(n));
        int sessionPid = -1;
        if (o && QMetaObject::invokeMethod(o, "processId", Q_RETURN_ARG(int, sessionPid)) && sessionPid == pid) {
            m_sessions.insert(id, o);
            return o;
        }
    }
    return nullptr;
}

bool MainWindow::type(const QString &sessionId, const QString &text, QString *error)
{
    auto *t = terminal(sessionId);
    if (!t) {
        *error = QStringLiteral("session has no terminal");
        return false;
    }
    t->sendInput(text);
    return true;
}

QString MainWindow::text(const QString &sessionId, QString *error)
{
    QString out;
    QObject *s = konsoleSession(sessionId);
    if (!s || !QMetaObject::invokeMethod(s, "getAllDisplayedText", Q_RETURN_ARG(QString, out), Q_ARG(bool, true)))
        *error = QStringLiteral("terminal text unavailable (Konsole session not found on the D-Bus session bus)");
    return out;
}

QJsonObject MainWindow::info(const QString &sessionId)
{
    auto *t = terminal(sessionId);
    if (!t)
        return {};
    return {{"pid", t->terminalProcessId()},
            {"foreground", t->foregroundProcessName()},
            {"foregroundPid", t->foregroundProcessId()},
            {"liveCwd", liveCwd(sessionId)},
            {"profile", t->currentProfileName()}};
}

void MainWindow::rebuildSidebar()
{
    m_rebuilding = true;
    m_tree->clear();
    for (const auto &w : m_store.workspaces) {
        auto *wi = new QTreeWidgetItem(m_tree, {w.name});
        wi->setData(0, IdRole, w.id);
        wi->setData(0, KindRole, WorkspaceKind);
        wi->setFlags(Qt::ItemIsEnabled);
        QFont f = wi->font(0);
        f.setBold(true);
        wi->setFont(0, f);
        for (const auto &s : w.sessions) {
            auto *si = new QTreeWidgetItem(wi, {s.name});
            si->setData(0, IdRole, s.id);
            si->setData(0, KindRole, SessionKind);
            si->setIcon(0, statusIcon(s.status));
            si->setToolTip(0, QStringLiteral("%1\n%2\n%3").arg(s.title, s.cwd, s.status));
            if (s.status == QLatin1String("blocked") || s.status == QLatin1String("completed")) {
                QFont sf = si->font(0);
                sf.setBold(true);
                si->setFont(0, sf);
            }
            if (s.id == m_store.selected)
                m_tree->setCurrentItem(si);
        }
        wi->setExpanded(!m_collapsed.contains(w.id));
    }
    m_rebuilding = false;
}

void MainWindow::showSelected()
{
    const Session *s = m_store.session(m_store.selected);
    auto *part = m_parts.value(m_store.selected);
    m_stack->setCurrentWidget(part ? part->widget() : static_cast<QWidget *>(m_empty));
    if (part && part->widget()->window()->isActiveWindow())
        part->widget()->setFocus();
    setWindowTitle(s ? QStringLiteral("%1 / %2 — %3").arg(m_store.workspaceOf(s->id)->name, s->name, s->title) : QStringLiteral("agterm-qt"));
}

void MainWindow::sidebarMenu(const QPoint &pos)
{
    QMenu menu;
    auto *item = m_tree->itemAt(pos);
    const QString id = item ? item->data(0, IdRole).toString() : QString();
    if (item && item->data(0, KindRole).toInt() == SessionKind) {
        menu.addAction(QIcon::fromTheme(QStringLiteral("edit-rename")), tr("Rename…"), this, [this, id] { renameSession(id); });
        menu.addAction(QIcon::fromTheme(QStringLiteral("tab-close")), tr("Close"), this, [this, id] { closeSession(id); });
        if (m_store.session(id)->status != QLatin1String("idle"))
            menu.addAction(tr("Clear Status"), this, [this, id] { m_store.setStatus(id, QStringLiteral("idle")); });
    } else if (item) {
        menu.addAction(QIcon::fromTheme(QStringLiteral("tab-new")), tr("New Session"), this, [this, id] { newSession(id); });
        menu.addAction(QIcon::fromTheme(QStringLiteral("edit-rename")), tr("Rename…"), this, [this, id] { renameWorkspace(id); });
        menu.addAction(QIcon::fromTheme(QStringLiteral("edit-delete")), tr("Delete Workspace"), this, [this, id] { deleteWorkspace(id); });
    }
    menu.addSeparator();
    menu.addAction(QIcon::fromTheme(QStringLiteral("folder-new")), tr("New Workspace…"), this, &MainWindow::newWorkspace);
    menu.exec(m_tree->viewport()->mapToGlobal(pos));
}

void MainWindow::newSession(const QString &workspaceId)
{
    QString ws = workspaceId;
    if (!m_store.workspace(ws))
        ws = m_store.addWorkspace(QStringLiteral("main"));
    // inherit the live directory of the current session, as a new tab would
    QString cwd;
    if (auto *w = m_store.workspaceOf(m_store.selected); w && w->id == ws)
        cwd = liveCwd(m_store.selected);
    m_store.select(m_store.addSession(ws, {}, cwd));
}

void MainWindow::newWorkspace()
{
    bool ok = false;
    const QString name = QInputDialog::getText(this, tr("New Workspace"), tr("Name:"), QLineEdit::Normal, {}, &ok);
    if (ok && !name.trimmed().isEmpty())
        m_store.select(m_store.addSession(m_store.addWorkspace(name.trimmed()), {}, {}));
}

void MainWindow::closeSession(const QString &id)
{
    const Session *s = m_store.session(id);
    if (!s)
        return;
    // closing hangs up whatever runs in the pane; ask only when that is more than the idle shell
    auto *t = terminal(id);
    const QString fg = t ? t->foregroundProcessName() : QString();
    const QString shell = QFileInfo(qEnvironmentVariable("SHELL", QStringLiteral("bash"))).fileName();
    if (!fg.isEmpty() && fg != shell
        && QMessageBox::question(this, tr("Close Session"), tr("“%1” is still running %2. Close it?").arg(s->name, fg)) != QMessageBox::Yes)
        return;
    m_store.removeSession(id);
}

void MainWindow::renameSession(const QString &id)
{
    const Session *s = m_store.session(id);
    if (!s)
        return;
    bool ok = false;
    const QString name = QInputDialog::getText(this, tr("Rename Session"), tr("Name:"), QLineEdit::Normal, s->name, &ok);
    if (ok)
        m_store.renameSession(id, name.trimmed());
}

void MainWindow::renameWorkspace(const QString &id)
{
    const Workspace *w = m_store.workspace(id);
    if (!w)
        return;
    bool ok = false;
    const QString name = QInputDialog::getText(this, tr("Rename Workspace"), tr("Name:"), QLineEdit::Normal, w->name, &ok);
    if (ok)
        m_store.renameWorkspace(id, name.trimmed());
}

void MainWindow::deleteWorkspace(const QString &id)
{
    const Workspace *w = m_store.workspace(id);
    if (!w)
        return;
    if (!w->sessions.isEmpty()
        && QMessageBox::question(this, tr("Delete Workspace"), tr("Close all %1 sessions in “%2”?").arg(w->sessions.size()).arg(w->name))
            != QMessageBox::Yes)
        return;
    m_store.removeWorkspace(id);
}

void MainWindow::go(const QString &direction)
{
    QString error;
    if (m_store.go(direction, &error).isEmpty())
        statusBar()->showMessage(error, 2000);
}

void MainWindow::profileDialog(const char *slot)
{
    auto *part = m_parts.value(m_store.selected);
    if (!part || !QMetaObject::invokeMethod(part, slot, Q_ARG(QWidget *, this)))
        statusBar()->showMessage(tr("Open a session first"), 2000);
}

void MainWindow::notify(const QString &id, const QString &status)
{
    const Session *s = m_store.session(id);
    if (!s || (status != QLatin1String("blocked") && status != QLatin1String("completed")))
        return;
    if (isActiveWindow() && id == m_store.selected)
        return;
    const QString text = status == QLatin1String("blocked") ? tr("%1 is waiting for you").arg(s->name) : tr("%1 finished").arg(s->name);
    auto *n = KNotification::event(KNotification::Notification, QStringLiteral("agterm-qt"), text, QStringLiteral("utilities-terminal"));
    auto *action = n->addDefaultAction(tr("Show"));
    connect(action, &KNotificationAction::activated, this, [this, id] {
        m_store.select(id);
        show();
        raise();
        activateWindow();
    });
}

void MainWindow::save()
{
    // Konsole signals directory changes only for a shown pane; /proc is authoritative for the rest
    for (auto *s : m_store.allSessions())
        if (const QString cwd = liveCwd(s->id); !cwd.isEmpty())
            s->cwd = cwd;
    QJsonObject root = m_store.toJson();
    QJsonArray collapsed;
    for (const auto &c : m_collapsed)
        collapsed << c;
    root.insert("window", QJsonObject{{"geometry", QString::fromLatin1(saveGeometry().toBase64())},
                                      {"splitter", QString::fromLatin1(m_split->saveState().toBase64())},
                                      {"sidebar", !m_tree->isHidden()},
                                      {"menubar", !menuBar()->isHidden()},
                                      {"collapsed", collapsed}});
    QSaveFile f(m_statePath);
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(root).toJson());
        f.commit();
    }
}

MainWindow::~MainWindow()
{
    // ~QWidget would delete the parts after our members are gone, while their destroyed handlers still run
    m_quitting = true;
    qDeleteAll(m_parts);
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    m_saveTimer.stop();
    save();
    m_quitting = true; // parts die with the window from here on; their sessions must stay saved
    QMainWindow::closeEvent(event);
}

bool MainWindow::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() == QEvent::KeyPress && !m_quitting) {
        auto *w = qobject_cast<QWidget *>(watched);
        if (w && m_stack->isAncestorOf(w) && !isOwnShortcut(static_cast<QKeyEvent *>(event)))
            m_store.keyPressed(m_store.selected);
    }
    return QMainWindow::eventFilter(watched, event);
}
