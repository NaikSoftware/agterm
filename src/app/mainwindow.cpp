#include "mainwindow.h"

#include "launcher.h"
#include "paths.h"
#include "sidebar.h"
#include "store.h"

#include <KParts/PartLoader>
#include <KParts/ReadOnlyPart>
#include <kde_terminal_interface.h>

#include <QAction>
#include <QApplication>
#include <QButtonGroup>
#include <QClipboard>
#include <QCheckBox>
#include <QCloseEvent>
#include <QComboBox>
#include <QDBusConnection>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QDirIterator>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QSaveFile>
#include <QSplitter>
#include <QScreen>
#include <QSplitterHandle>
#include <QStackedLayout>
#include <QStackedWidget>
#include <QWindow>
#include <QStatusBar>
#include <QToolBar>
#include <QToolButton>
#include <QVBoxLayout>

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
    setWindowIcon(QIcon::fromTheme(QStringLiteral("utilities-terminal")));
    m_tree = new Sidebar(store);

    // footer: new session, new workspace, and the flagged view toggle, as agterm's sidebar bar
    auto footerButton = [](const QString &icon, const QString &tip) {
        auto *b = new QToolButton;
        b->setIcon(QIcon::fromTheme(icon));
        b->setToolTip(tip);
        b->setAccessibleName(tip);
        b->setAutoRaise(true);
        b->setFocusPolicy(Qt::NoFocus);
        return b;
    };
    auto *newSessionButton = footerButton(QStringLiteral("tab-new"), tr("New Session"));
    connect(newSessionButton, &QToolButton::clicked, this, [this] { newSession(currentWorkspace()); });
    auto *newWorkspaceButton = footerButton(QStringLiteral("list-add"), tr("New Workspace"));
    connect(newWorkspaceButton, &QToolButton::clicked, this, &MainWindow::newWorkspace);
    m_flagButton = footerButton(QStringLiteral("flag"), tr("Flagged Sessions"));
    m_flagButton->setCheckable(true);
    connect(m_flagButton, &QToolButton::toggled, this, [this](bool on) {
        m_tree->setFlaggedView(on);
        m_actions.value(QStringLiteral("toggle_flagged_view"))->setChecked(on);
        m_saveTimer.start();
    });
    auto *footer = new QHBoxLayout;
    footer->setContentsMargins(8, 4, 8, 6);
    footer->setSpacing(2);
    footer->addWidget(newSessionButton);
    footer->addWidget(newWorkspaceButton);
    footer->addStretch(1);
    footer->addWidget(m_flagButton);

    m_sidebarPanel = new QWidget;
    auto *side = new QVBoxLayout(m_sidebarPanel);
    side->setContentsMargins(0, 6, 0, 0);
    side->setSpacing(0);
    side->addWidget(m_tree, 1);
    side->addLayout(footer);

    m_stack = new QStackedWidget;
    m_empty = new QWidget;
    m_stack->addWidget(m_empty);

    m_split = new QSplitter;
    m_split->setChildrenCollapsible(false);
    m_split->addWidget(m_sidebarPanel);
    m_split->addWidget(m_stack);
    m_split->setStretchFactor(1, 1);
    m_split->setSizes({230, 970});
    m_sidebarPanel->setMinimumWidth(160);
    setCentralWidget(m_split);
    resize(1200, 760);
    // messages only: an idle status bar would be chrome agterm doesn't have
    statusBar()->hide();
    connect(statusBar(), &QStatusBar::messageChanged, statusBar(), [this](const QString &m) { statusBar()->setVisible(!m.isEmpty()); });

    createMenus();

    // title strip: sidebar toggle and the session name, as agterm's title bar
    auto *strip = new QToolBar;
    strip->setObjectName(QStringLiteral("titleStrip"));
    strip->setMovable(false);
    strip->setFloatable(false);
    strip->setIconSize(QSize(16, 16));
    strip->toggleViewAction()->setVisible(false);
    // a plain button, not the checkable menu action: agterm's toggle never renders pressed
    const QColor ink = palette().color(QPalette::WindowText);
    strip->addAction(chromeIcon(QStringLiteral("sidebar"), ink), tr("Toggle Sidebar"), m_sidebarAction, &QAction::trigger);
    m_title = new QLabel;
    QFont tf = m_title->font();
    tf.setWeight(QFont::DemiBold);
    m_title->setFont(tf);
    m_title->setContentsMargins(6, 0, 0, 0);
    strip->addWidget(m_title);
    auto *spacer = new QWidget;
    spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    strip->addWidget(spacer);
    strip->addAction(chromeIcon(QStringLiteral("scratch"), ink), tr("Scratch"), m_actions.value(QStringLiteral("toggle_scratch")), &QAction::trigger);
    strip->addAction(chromeIcon(QStringLiteral("split"), ink), tr("Split"), m_actions.value(QStringLiteral("toggle_split")), &QAction::trigger);
    strip->addSeparator();
    strip->addAction(launcherIcon(QStringLiteral("terminal"), ink), tr("Quick Terminal"), m_actions.value(QStringLiteral("quick_terminal")), &QAction::trigger);
    addToolBar(Qt::TopToolBarArea, strip);
    m_strip = strip;

    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(500);
    connect(&m_saveTimer, &QTimer::timeout, this, &MainWindow::save);
    m_agentTimer.setInterval(2000);
    connect(&m_agentTimer, &QTimer::timeout, this, &MainWindow::sampleAgents);
    m_agentTimer.start();

    connect(&m_store, &Store::changed, this, [this] {
        m_tree->rebuild();
        showSelected();
        m_saveTimer.start();
    });
    connect(&m_store, &Store::titleChanged, this, [this] {
        m_tree->rebuild();
        showSelected();
    });
    connect(&m_store, &Store::sessionAdded, this, &MainWindow::createTerminal);
    connect(&m_store, &Store::sessionRemoved, this, [this](const QString &id) {
        m_sessions.remove(id);
        // taken first, so the parts dying with their view are not mistaken for shells that exited
        if (Panes p = m_panes.take(id); p.view)
            p.view->deleteLater(); // closes the ptys, which hangs up the shells
    });
    connect(&m_store, &Store::selectionChanged, this, &MainWindow::showSelected);
    connect(&m_store, &Store::paneLayoutChanged, this, &MainWindow::applyLayout);
    connect(&m_store, &Store::swapRequested, this, &MainWindow::swapPanes);
    connect(m_tree, &QTreeWidget::currentItemChanged, this, [this](QTreeWidgetItem *item) {
        if (item && item->data(0, SidebarRole::Kind).toInt() == SidebarRole::SessionRow)
            m_store.select(item->data(0, SidebarRole::Id).toString());
    });
    connect(m_tree, &QTreeWidget::customContextMenuRequested, this, &MainWindow::sidebarMenu);
    connect(m_tree, &Sidebar::launcherMenuRequested, this, &MainWindow::launcherMenu);
    connect(m_tree, &Sidebar::repeatRequested, this, [this](const QString &ws) { launch(m_store.settings.lastLauncher, ws); });
    connect(m_tree, &Sidebar::renameRequested, this, [this](const QString &kind, const QString &id, const QString &name) {
        kind == QLatin1String("session") ? m_store.renameSession(id, name) : m_store.renameWorkspace(id, name);
        m_tree->rebuild();
    });
    connect(m_tree, &Sidebar::foldersDropped, this, [this](const QString &ws, const QStringList &dirs) {
        const QString target = m_store.workspace(ws) ? ws : currentWorkspace();
        QString last;
        for (const auto &d : dirs)
            last = m_store.addSession(target, {}, d);
        m_store.select(last);
    });
    qApp->installEventFilter(this);
    detectLaunchers();
}

QAction *MainWindow::action(const QString &name, const QString &text, const QString &icon, const QKeySequence &key, std::function<void()> slot)
{
    auto *a = new QAction(QIcon::fromTheme(icon), text, this);
    a->setShortcut(key);
    a->setShortcutContext(Qt::ApplicationShortcut);
    connect(a, &QAction::triggered, this, slot);
    addAction(a); // shortcuts work with the menu bar hidden
    m_actions.insert(name, a);
    return a;
}

void MainWindow::createMenus()
{
    // agterm's ⌘ is Ctrl+Shift here (Konsole's convention), ⌘⇧ and ⌘⌃ are Ctrl+Alt+Shift, ⌥ is Alt, ⌃ is Ctrl
    auto *file = menuBar()->addMenu(tr("&File"));
    file->addAction(action(QStringLiteral("new_session"), tr("New Session"), QStringLiteral("tab-new"), QKeySequence(QStringLiteral("Ctrl+Shift+N")),
                           [this] { newSession(currentWorkspace()); }));
    file->addAction(action(QStringLiteral("new_workspace"), tr("New Workspace…"), QStringLiteral("list-add"),
                           QKeySequence(QStringLiteral("Ctrl+Alt+Shift+N")), [this] { newWorkspace(); }));
    file->addAction(action(QStringLiteral("open_directory"), tr("Open Directory…"), QStringLiteral("folder-open"),
                           QKeySequence(QStringLiteral("Ctrl+Shift+O")), [this] { openDirectory(); }));
    file->addSeparator();
    file->addAction(action(QStringLiteral("close_session"), tr("Close Session"), QStringLiteral("tab-close"), QKeySequence(QStringLiteral("Ctrl+Shift+W")),
                           [this] { m_zoomed ? toggleZoom() : closeSessions({m_store.selected}); })); // ⌘W leaves zoom first
    file->addAction(action(QStringLiteral("reopen_recent"), tr("Reopen Closed Session"), QStringLiteral("edit-undo"),
                           QKeySequence(QStringLiteral("Ctrl+Alt+Shift+T")), [this] {
                               if (m_store.reopenClosed().isEmpty())
                                   statusBar()->showMessage(tr("Nothing to reopen"), 2000);
                           }));
    file->addSeparator();
    file->addAction(action(QStringLiteral("quit"), tr("Quit"), QStringLiteral("application-exit"), QKeySequence(QStringLiteral("Ctrl+Shift+Q")),
                           [this] { close(); }));

    auto *session = menuBar()->addMenu(tr("&Session"));
    session->addAction(action(QStringLiteral("rename_session"), tr("Rename Session"), QStringLiteral("edit-rename"), {}, [this] {
        if (QTreeWidgetItem *item = m_tree->currentItem())
            m_tree->editItem(item);
    }));
    session->addAction(action(QStringLiteral("duplicate_session"), tr("Duplicate Session"), QStringLiteral("edit-copy"), {}, [this] {
        if (m_store.session(m_store.selected))
            m_store.select(m_store.duplicateSession(m_store.selected, liveCwd(m_store.selected)));
    }));
    session->addAction(action(QStringLiteral("clear_status"), tr("Clear Status"), QStringLiteral("edit-clear"), {},
                              [this] { m_store.setStatus(m_store.selected, QStringLiteral("idle")); }));
    session->addAction(action(QStringLiteral("toggle_flag"), tr("Flag"), QStringLiteral("flag"), QKeySequence(QStringLiteral("Ctrl+Alt+Shift+F")), [this] {
        if (const Session *s = m_store.session(m_store.selected))
            m_store.setFlag(s->id, !s->flagged);
    }));

    auto *view = menuBar()->addMenu(tr("&View"));
    m_sidebarAction = action(QStringLiteral("toggle_sidebar"), tr("Show Sidebar"), QStringLiteral("sidebar-show-symbolic"),
                             QKeySequence(QStringLiteral("Ctrl+Alt+Shift+S")), [this] {
                                 m_sidebarPanel->setVisible(m_sidebarAction->isChecked());
                                 m_saveTimer.start();
                             });
    m_sidebarAction->setCheckable(true);
    m_sidebarAction->setChecked(true);
    m_sidebarAction->setToolTip(tr("Toggle Sidebar"));
    view->addAction(m_sidebarAction);
    auto *flagged = action(QStringLiteral("toggle_flagged_view"), tr("Flagged Sessions"), QStringLiteral("flag"), {},
                           [this] { m_flagButton->setChecked(m_actions.value(QStringLiteral("toggle_flagged_view"))->isChecked()); });
    flagged->setCheckable(true);
    view->addAction(flagged);
    view->addAction(action(QStringLiteral("toggle_menubar"), tr("Show Menu Bar"), QStringLiteral("show-menu"), QKeySequence(QStringLiteral("Ctrl+Shift+M")),
                           [this] { menuBar()->setVisible(!menuBar()->isVisible()); }));
    view->addSeparator();
    view->addAction(action(QStringLiteral("toggle_split"), tr("Split"), {}, QKeySequence(QStringLiteral("Ctrl+Shift+D")),
                           [this] { m_store.toggleSplit(m_store.selected, QStringLiteral("vertical")); }));
    view->addAction(action(QStringLiteral("toggle_horizontal_split"), tr("Split Horizontally"), {}, QKeySequence(QStringLiteral("Ctrl+Alt+Shift+D")),
                           [this] { m_store.toggleSplit(m_store.selected, QStringLiteral("horizontal")); }));
    view->addAction(action(QStringLiteral("swap_panes"), tr("Swap Panes"), {}, {}, [this] { swapPanes(m_store.selected); }));
    view->addAction(action(QStringLiteral("close_split"), tr("Close Split"), {}, {}, [this] {
        if (const Session *s = m_store.session(m_store.selected); s && s->hasSplit)
            m_store.setSplit(s->id, false, false, s->splitAxis);
    }));
    view->addAction(action(QStringLiteral("focus_left_pane"), tr("Focus Left Pane"), {}, QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Left")),
                           [this] { focusPane(false); }));
    view->addAction(action(QStringLiteral("focus_right_pane"), tr("Focus Right Pane"), {}, QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Right")),
                           [this] { focusPane(true); }));
    view->addAction(action(QStringLiteral("toggle_scratch"), tr("Scratch"), {}, QKeySequence(QStringLiteral("Ctrl+Shift+J")), [this] {
        if (const Session *s = m_store.session(m_store.selected))
            m_store.setScratch(s->id, !s->scratchVisible);
    }));
    view->addSeparator();
    view->addAction(action(QStringLiteral("quick_terminal"), tr("Quick Terminal"), QStringLiteral("utilities-terminal"), QKeySequence(QStringLiteral("Ctrl+`")),
                           [this] { showQuick(!quickVisible(), false); }));
    view->addAction(action(QStringLiteral("toggle_terminal_zoom"), tr("Terminal Zoom"), QStringLiteral("zoom-fit-best"),
                           QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Return")), [this] { toggleZoom(); }));
    view->addAction(action(QStringLiteral("toggle_fullscreen"), tr("Full Screen"), QStringLiteral("view-fullscreen"), QKeySequence(QStringLiteral("F11")),
                           [this] { setWindowState(windowState() ^ Qt::WindowFullScreen); }));

    auto *nav = menuBar()->addMenu(tr("&Navigate"));
    nav->addAction(action(QStringLiteral("previous_session"), tr("Previous Session"), QStringLiteral("go-up"),
                          QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Up")), [this] { go(QStringLiteral("prev")); }));
    nav->addAction(action(QStringLiteral("next_session"), tr("Next Session"), QStringLiteral("go-down"),
                          QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Down")), [this] { go(QStringLiteral("next")); }));
    nav->addAction(action(QStringLiteral("previous_attention_session"), tr("Previous Attention Session"), QStringLiteral("go-up-skip"),
                          QKeySequence(QStringLiteral("Ctrl+Alt+Up")), [this] { go(QStringLiteral("prev-attention")); }));
    nav->addAction(action(QStringLiteral("next_attention_session"), tr("Next Attention Session"), QStringLiteral("go-down-skip"),
                          QKeySequence(QStringLiteral("Ctrl+Alt+Down")), [this] { go(QStringLiteral("next-attention")); }));
    nav->addAction(action(QStringLiteral("first_session"), tr("First Session"), QStringLiteral("go-top"), {}, [this] { go(QStringLiteral("first")); }));
    nav->addAction(action(QStringLiteral("last_session"), tr("Last Session"), QStringLiteral("go-bottom"), {}, [this] { go(QStringLiteral("last")); }));

    auto *settings = menuBar()->addMenu(tr("Se&ttings"));
    settings->addAction(action(QStringLiteral("settings"), tr("Configure agterm…"), QStringLiteral("configure"), QKeySequence(QStringLiteral("Ctrl+Shift+,")),
                               [this] { showSettings(); }));
    settings->addAction(action(QStringLiteral("edit_profile"), tr("Edit Current Profile…"), QStringLiteral("document-edit"), {},
                               [this] { profileDialog("showEditCurrentProfileDialog"); }));
    settings->addAction(action(QStringLiteral("manage_profiles"), tr("Manage Profiles…"), QStringLiteral("configure-shortcuts"), {},
                               [this] { profileDialog("showManageProfilesDialog"); }));
}

bool MainWindow::isOwnShortcut(QKeyEvent *event) const
{
    const QKeySequence key(event->keyCombination());
    for (const QAction *a : actions())
        if (!a->shortcut().isEmpty() && a->shortcut().matches(key) == QKeySequence::ExactMatch)
            return true;
    return false;
}

void MainWindow::setSocketStatus(bool ok, const QString &error)
{
    if (!ok)
        statusBar()->showMessage(tr("Control socket unavailable: %1").arg(error));
}

void MainWindow::restore(const QJsonObject &window)
{
    for (auto *s : m_store.allSessions())
        createTerminal(s->id);
    restoreGeometry(QByteArray::fromBase64(window.value("geometry").toString().toLatin1()));
    m_split->restoreState(QByteArray::fromBase64(window.value("splitter").toString().toLatin1()));
    for (const auto &v : window.value("collapsed").toArray())
        m_tree->m_collapsed.insert(v.toString());
    m_sidebarAction->setChecked(window.value("sidebar").toBool(true));
    m_sidebarPanel->setVisible(m_sidebarAction->isChecked());
    m_flagButton->setChecked(window.value("flaggedView").toBool(false));
    m_tree->rebuild();
    showSelected();
}

KParts::ReadOnlyPart *MainWindow::spawnPart(const QString &id, const QString &pane, const QString &cwd, const QString &command, QWidget *parent)
{
    auto result = KParts::PartLoader::instantiatePart<KParts::ReadOnlyPart>(KPluginMetaData(QStringLiteral("kf6/parts/konsolepart")), parent, this);
    if (!result) {
        statusBar()->showMessage(tr("Cannot load the Konsole part: %1").arg(result.errorString));
        return nullptr;
    }
    KParts::ReadOnlyPart *part = result.plugin;
    auto *bridge = new PartBridge(this, m_store, id, part);
    connect(part, SIGNAL(currentDirectoryChanged(QString)), bridge, SLOT(currentDirectoryChanged(QString)));
    connect(part, SIGNAL(overrideShortcut(QKeyEvent *, bool &)), bridge, SLOT(overrideShortcut(QKeyEvent *, bool &)));
    if (pane == QLatin1String("main"))
        connect(part, &KParts::Part::setWindowCaption, this, [this, id](const QString &title) { m_store.setTitle(id, title); });
    // the part deletes itself when its shell exits
    connect(part, &QObject::destroyed, this, [this, id, part] {
        if (!m_quitting)
            paneExited(id, part);
    });

    const QString dir = QFileInfo(cwd).isDir() ? cwd : QDir::homePath();
    const QString appDir = QCoreApplication::applicationDirPath();
    const QString shell = qEnvironmentVariable("SHELL", QStringLiteral("/bin/bash"));
    QStringList argv{QStringLiteral("/usr/bin/env"),
                     QStringLiteral("-C"),
                     dir,
                     QStringLiteral("AGTERM_SESSION_ID=") + id,
                     QStringLiteral("AGTERM_WORKSPACE_ID=") + m_store.workspaceOf(id)->id,
                     QStringLiteral("AGTERM_PANE=") + pane,
                     QStringLiteral("AGTERM_SOCKET=") + socketPath(),
                     QStringLiteral("AGTERMCTL=") + appDir + QStringLiteral("/agtermctl"),
                     QStringLiteral("PATH=") + appDir + QLatin1Char(':') + qEnvironmentVariable("PATH"),
                     shell};
    if (!command.isEmpty())
        argv << QStringLiteral("-c") << command;
    qobject_cast<TerminalInterface *>(part)->startProgram(argv.first(), argv);
    return part;
}

void MainWindow::createTerminal(const QString &id)
{
    const Session *s = m_store.session(id);
    Panes p;
    p.view = new QWidget;
    p.layers = new QStackedLayout(p.view);
    p.split = new QSplitter;
    p.split->setChildrenCollapsible(false);
    p.layers->addWidget(p.split);
    p.main = spawnPart(id, QStringLiteral("main"), s->cwd, s->command, p.split);
    if (!p.main) {
        delete p.view;
        return;
    }
    p.split->addWidget(p.main->widget());
    connect(p.split, &QSplitter::splitterMoved, this, [this, id] {
        Session *s = m_store.session(id);
        const auto &pp = m_panes[id];
        const QList<int> sizes = pp.split->sizes();
        if (s && sizes.size() == 2 && sizes[0] + sizes[1] > 0) {
            s->splitRatio = double(sizes[0]) / (sizes[0] + sizes[1]);
            m_saveTimer.start();
        }
    });
    m_panes.insert(id, p);
    m_stack->addWidget(p.view);
    applyLayout(id);
    prime(p.view);
}

void MainWindow::applyLayout(const QString &id)
{
    Session *s = m_store.session(id);
    if (!s || !m_panes.contains(id))
        return;
    Panes &p = m_panes[id];
    if (s->hasSplit && !p.right) {
        p.right = spawnPart(id, QStringLiteral("right"), liveCwd(id).isEmpty() ? s->cwd : liveCwd(id), {}, p.split);
        if (p.right)
            p.split->addWidget(p.right->widget());
        p.split->handle(1)->installEventFilter(this); // double-click resets an even split
        p.split->handle(1)->setProperty("agtermSession", id);
    } else if (!s->hasSplit && p.right) {
        auto *right = std::exchange(p.right, nullptr);
        delete right; // closes the split shell whatever it runs
    }
    p.split->setOrientation(s->splitAxis == QLatin1String("horizontal") ? Qt::Vertical : Qt::Horizontal);
    if (p.right) {
        p.right->widget()->setVisible(s->splitVisible);
        const int total = 10000;
        p.split->setSizes({int(total * s->splitRatio), total - int(total * s->splitRatio)});
    }
    if (s->scratchVisible && !p.scratch) {
        p.scratch = spawnPart(id, QStringLiteral("scratch"), liveCwd(id).isEmpty() ? s->cwd : liveCwd(id), {}, p.view);
        if (p.scratch)
            p.layers->addWidget(p.scratch->widget());
    }
    QWidget *front = s->scratchVisible && p.scratch ? p.scratch->widget() : static_cast<QWidget *>(p.split);
    p.layers->setCurrentWidget(front);
    if (KParts::ReadOnlyPart *target = front == p.split ? p.main : p.scratch; target && id == m_store.selected && isActiveWindow())
        target->widget()->setFocus();
}

void MainWindow::paneExited(const QString &id, KParts::ReadOnlyPart *part)
{
    if (!m_panes.contains(id))
        return;
    Panes &p = m_panes[id];
    if (part == p.scratch) {
        p.scratch = nullptr;
        m_store.setScratch(id, false);
    } else if (part == p.right) {
        p.right = nullptr;
        m_store.setSplit(id, false, false, m_store.session(id)->splitAxis);
    } else if (part == p.main) {
        p.main = nullptr;
        m_sessions.remove(id);
        if (p.right) { // the split survivor becomes the session's only shell
            p.main = std::exchange(p.right, nullptr);
            p.main->widget()->show();
            m_store.setSplit(id, false, false, m_store.session(id)->splitAxis);
        } else {
            m_store.removeSession(id);
        }
    }
}

void MainWindow::swapPanes(const QString &id)
{
    Panes &p = m_panes[id];
    if (!p.right)
        return;
    p.split->insertWidget(0, p.right->widget()); // physical positions and the primary role move together
    std::swap(p.main, p.right);
    m_sessions.remove(id);
}

void MainWindow::focusPane(bool right)
{
    const Panes p = m_panes.value(m_store.selected);
    KParts::ReadOnlyPart *target = right ? p.right : p.main;
    if (target && target->widget()->isVisible())
        target->widget()->setFocus();
}

void MainWindow::toggleZoom()
{
    // a view mode: everything but the terminal hides, and comes back exactly as it was
    m_zoomed = !m_zoomed;
    if (m_zoomed) {
        m_zoomRestoreSidebar = m_sidebarPanel->isVisible();
        m_zoomRestoreMenu = menuBar()->isVisible();
    }
    m_sidebarPanel->setVisible(!m_zoomed && m_zoomRestoreSidebar);
    menuBar()->setVisible(!m_zoomed && m_zoomRestoreMenu);
    m_strip->setVisible(!m_zoomed);
}

bool MainWindow::quickVisible() const
{
    return m_quick && m_quick->isVisible();
}

bool MainWindow::quick(const QString &mode, QString *)
{
    showQuick(mode == QLatin1String("on"), true);
    return true;
}

void MainWindow::showQuick(bool on, bool pinned)
{
    if (!on) {
        if (m_quick)
            m_quick->hide(); // hiding keeps its shell alive
        return;
    }
    if (!m_quick) {
        m_quick = new QWidget(nullptr, Qt::Window | Qt::FramelessWindowHint);
        m_quick->setWindowTitle(tr("Quick Terminal"));
        new QVBoxLayout(m_quick);
        m_quick->layout()->setContentsMargins(0, 0, 0, 0);
        m_quick->installEventFilter(this);
    }
    if (!m_quickPart) {
        // one throwaway shell for the whole app, opened in the active session's directory
        const QString cwd = liveCwd(m_store.selected);
        auto result = KParts::PartLoader::instantiatePart<KParts::ReadOnlyPart>(KPluginMetaData(QStringLiteral("kf6/parts/konsolepart")), m_quick, this);
        if (!result)
            return;
        m_quickPart = result.plugin;
        m_quick->layout()->addWidget(m_quickPart->widget());
        auto *bridge = new PartBridge(this, m_store, {}, m_quickPart);
        connect(m_quickPart, SIGNAL(overrideShortcut(QKeyEvent *, bool &)), bridge, SLOT(overrideShortcut(QKeyEvent *, bool &)));
        connect(m_quickPart, &QObject::destroyed, this, [this] {
            m_quickPart = nullptr;
            if (!m_quitting && m_quick)
                m_quick->hide();
        });
        qobject_cast<TerminalInterface *>(m_quickPart)->showShellInDir(cwd.isEmpty() ? QDir::homePath() : cwd);
    }
    m_quickPinned = pinned;
    const QRect screen = (windowHandle() && windowHandle()->screen() ? windowHandle()->screen() : QGuiApplication::primaryScreen())->availableGeometry();
    const QSize size(qMin(int(screen.width() * 0.9), 1600), qMin(int(screen.height() * 0.9), 1000));
    m_quick->setGeometry(QRect(screen.center() - QPoint(size.width() / 2, size.height() / 2), size));
    m_quick->show();
    m_quick->raise();
    m_quick->activateWindow();
    m_quickPart->widget()->setFocus();
}

TerminalInterface *MainWindow::terminal(const QString &id) const
{
    auto *part = m_panes.value(id).main;
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
    for (const Panes &p : std::as_const(m_panes))
        prime(p.view);
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
    if (text.contains(QLatin1Char('\n')) || text.contains(QLatin1Char('\r')))
        m_store.keyPressed(sessionId, Store::Key::Submit); // injected text carrying a newline is a submit
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

void MainWindow::showSelected()
{
    const Session *s = m_store.session(m_store.selected);
    const Panes p = m_panes.value(m_store.selected);
    m_stack->setCurrentWidget(p.view ? p.view : m_empty);
    // focus moves only with the selection, so a status repaint never pulls it out of the split pane
    if (p.view && m_shownId != m_store.selected && isActiveWindow() && !m_tree->editing()) {
        KParts::ReadOnlyPart *front = s->scratchVisible && p.scratch ? p.scratch : p.main;
        if (front)
            front->widget()->setFocus();
    }
    m_shownId = m_store.selected;
    const QString name = s ? s->displayName() : QString();
    m_title->setText(name);
    setWindowTitle(name);
}

QString MainWindow::currentWorkspace()
{
    QString error;
    const QString ws = m_store.resolveWorkspace({}, &error);
    return ws.isEmpty() ? m_store.addWorkspace(QStringLiteral("main")) : ws;
}

void MainWindow::newSession(const QString &workspaceId)
{
    const QString ws = m_store.workspace(workspaceId) ? workspaceId : currentWorkspace();
    m_store.select(m_store.addSession(ws, {}, m_store.newSessionCwd(ws, liveCwd(m_store.selected))));
}

void MainWindow::launch(const QString &launcherId, const QString &workspaceId)
{
    const Launcher *l = launcher(launcherId);
    if (!l)
        return;
    Settings s = m_store.settings;
    s.lastLauncher = l->id;
    m_store.setSettings(s);
    newSession(workspaceId);
    if (!l->command.isEmpty()) {
        QString error;
        type(m_store.selected, l->command + QLatin1Char('\n'), &error); // typed into the shell, so the shell remains when it exits
    }
}

void MainWindow::launcherMenu(const QString &workspaceId, const QPoint &globalPos)
{
    detectLaunchers();
    QMenu menu;
    const QColor ink = palette().color(QPalette::WindowText);
    for (const QString &id : std::as_const(m_launchers))
        if (const Launcher *l = launcher(id))
            menu.addAction(launcherIcon(id, ink), l->title, this, [this, id, workspaceId] { launch(id, workspaceId); });
    menu.exec(globalPos);
}

void MainWindow::detectLaunchers()
{
    // agents install into directories only the user's shell startup adds to PATH, so ask a login shell
    if (m_launchersAt.isValid() && m_launchersAt.secsTo(QDateTime::currentDateTime()) < 300)
        return;
    m_launchersAt = QDateTime::currentDateTime();
    auto *proc = new QProcess(this);
    const QString marker = QStringLiteral("agterm-launcher-path");
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("AGTERM_SESSION_ID"));
    proc->setProcessEnvironment(env);
    proc->setStandardInputFile(QProcess::nullDevice());
    connect(proc, &QProcess::finished, this, [this, proc, marker] {
        const QString out = QString::fromUtf8(proc->readAllStandardOutput());
        const int at = out.lastIndexOf(marker + QLatin1Char('\n'));
        const QString shellPath = at < 0 ? QString() : out.mid(at + marker.size() + 1).trimmed();
        const QString path = QStringList{shellPath, qEnvironmentVariable("PATH"), QDir::homePath() + QStringLiteral("/.local/bin")}.join(QLatin1Char(':'));
        m_launchers = ::availableLaunchers(path, [](const QString &f) { return QFileInfo(f).isExecutable() && QFileInfo(f).isFile(); });
        proc->deleteLater();
    });
    QTimer::singleShot(3000, proc, [proc] { proc->kill(); });
    proc->start(qEnvironmentVariable("SHELL", QStringLiteral("/bin/bash")),
                {QStringLiteral("-l"), QStringLiteral("-i"), QStringLiteral("-c"), QStringLiteral("printf '\\n%s\\n' %1; printenv PATH").arg(marker)});
}

void MainWindow::sampleAgents()
{
    // the agent icon follows whatever runs in the foreground, typed by hand or by a script
    QHash<int, QList<int>> groups; // pgid -> pids, leader first
    for (QDirIterator it(QStringLiteral("/proc"), QDir::Dirs | QDir::NoDotAndDotDot); it.hasNext();) {
        bool numeric = false;
        const int pid = it.nextFileInfo().fileName().toInt(&numeric);
        if (!numeric)
            continue;
        QFile stat(QStringLiteral("/proc/%1/stat").arg(pid));
        if (!stat.open(QIODevice::ReadOnly))
            continue;
        const QByteArray line = stat.readAll();
        const QList<QByteArray> fields = line.mid(line.lastIndexOf(')') + 2).split(' ');
        if (fields.size() < 3)
            continue;
        const int pgid = fields[2].toInt();
        pid == pgid ? groups[pgid].prepend(pid) : groups[pgid].append(pid);
    }
    for (auto *s : m_store.allSessions()) {
        auto *t = terminal(s->id);
        const int fg = t ? t->foregroundProcessId() : -1;
        QList<QStringList> argvs;
        for (int pid : groups.value(fg)) {
            QFile f(QStringLiteral("/proc/%1/cmdline").arg(pid));
            if (f.open(QIODevice::ReadOnly))
                argvs << QString::fromUtf8(f.readAll()).split(QChar(0), Qt::SkipEmptyParts);
        }
        m_store.setAgent(s->id, agentForGroup(argvs));
    }
}

void MainWindow::newWorkspace()
{
    bool ok = false;
    const QString name = QInputDialog::getText(this, tr("New Workspace"), tr("Name:"), QLineEdit::Normal, {}, &ok);
    if (ok && !name.trimmed().isEmpty())
        m_store.addWorkspace(name.trimmed());
}

void MainWindow::openDirectory()
{
    const Session *cur = m_store.session(m_store.selected);
    const QString dir = QFileDialog::getExistingDirectory(this, tr("Open Directory"), cur ? liveCwd(cur->id) : QDir::homePath());
    if (dir.isEmpty())
        return;
    const QString remembering = m_store.workspaceRemembering(dir);
    m_store.select(m_store.addSession(remembering.isEmpty() ? currentWorkspace() : remembering, {}, dir));
}

void MainWindow::closeSessions(const QStringList &ids)
{
    QStringList live;
    for (const auto &id : ids)
        if (m_store.session(id))
            live << id;
    if (live.isEmpty())
        return;
    if (m_store.settings.confirmCloseSession
        && QMessageBox::question(this, tr("Close Session"),
                                 live.size() == 1 ? tr("Close “%1”?").arg(m_store.session(live.first())->displayName())
                                                  : tr("Close %1 sessions?").arg(live.size()))
               != QMessageBox::Yes)
        return;
    for (const auto &id : live)
        m_store.removeSession(id);
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

void MainWindow::fillMoveMenu(QMenu *menu, const QStringList &ids)
{
    const Workspace *from = m_store.workspaceOf(ids.value(0));
    for (const auto &w : m_store.workspaces) {
        auto *a = menu->addAction(w.name, this, [this, ids, wid = w.id] {
            for (const auto &id : ids)
                m_store.moveSession(id, wid, -1);
        });
        a->setEnabled(ids.size() > 1 || !from || from->id != w.id);
    }
    menu->addSeparator();
    menu->addAction(tr("New Workspace…"), this, [this, ids] {
        bool ok = false;
        const QString name = QInputDialog::getText(this, tr("New Workspace"), tr("Name:"), QLineEdit::Normal, {}, &ok);
        if (!ok || name.trimmed().isEmpty())
            return;
        const QString ws = m_store.addWorkspace(name.trimmed());
        for (const auto &id : ids)
            m_store.moveSession(id, ws, -1);
    });
}

void MainWindow::sidebarMenu(const QPoint &pos)
{
    QMenu menu;
    QTreeWidgetItem *item = m_tree->itemAt(pos);
    if (!item) {
        menu.addAction(QIcon::fromTheme(QStringLiteral("list-add")), tr("New Workspace…"), this, &MainWindow::newWorkspace);
        menu.exec(m_tree->viewport()->mapToGlobal(pos));
        return;
    }
    const QString id = item->data(0, SidebarRole::Id).toString();
    if (item->data(0, SidebarRole::Kind).toInt() == SidebarRole::SessionRow) {
        // right-clicking inside the selection acts on all of it; outside narrows to the row
        QStringList ids = m_tree->selectedSessionIds();
        if (!ids.contains(id))
            ids = {id};
        const Session *s = m_store.session(id);
        if (ids.size() == 1) {
            auto *clear = menu.addAction(tr("Clear Status"), this, [this, id] { m_store.setStatus(id, QStringLiteral("idle")); });
            clear->setEnabled(s->status != QLatin1String("idle"));
            menu.addSeparator();
            menu.addAction(tr("Rename"), this, [this, item] { m_tree->editItem(item); });
            menu.addAction(tr("Copy Name"), this, [s] { QApplication::clipboard()->setText(s->displayName()); });
            menu.addAction(tr("Duplicate Session"), this, [this, id] { m_store.select(m_store.duplicateSession(id, liveCwd(id))); });
        }
        fillMoveMenu(menu.addMenu(tr("Move to")), ids);
        bool allFlagged = true;
        for (const auto &sid : ids)
            allFlagged &= m_store.session(sid)->flagged;
        menu.addAction(allFlagged ? tr("Unflag") : tr("Flag"), this, [this, ids, allFlagged] {
            for (const auto &sid : ids)
                m_store.setFlag(sid, !allFlagged);
        });
        menu.addAction(ids.size() == 1 ? tr("Close Session") : tr("Close %1 Sessions").arg(ids.size()), this, [this, ids] { closeSessions(ids); });
    } else {
        const Workspace *w = m_store.workspace(id);
        menu.addAction(QIcon::fromTheme(QStringLiteral("tab-new")), tr("New Session"), this, [this, id] { newSession(id); });
        menu.addSeparator();
        menu.addAction(tr("Rename"), this, [this, item] { m_tree->editItem(item); });
        menu.addAction(tr("Copy Name"), this, [w] { QApplication::clipboard()->setText(w->name); });
        bool allFlagged = !w->sessions.isEmpty();
        for (const auto &s : w->sessions)
            allFlagged &= s.flagged;
        auto *flag = menu.addAction(allFlagged ? tr("Unflag All Sessions") : tr("Flag All Sessions"), this, [this, id, allFlagged] {
            QStringList ids;
            for (const auto &s : m_store.workspace(id)->sessions)
                ids << s.id;
            for (const auto &sid : ids)
                m_store.setFlag(sid, !allFlagged);
        });
        flag->setEnabled(!w->sessions.isEmpty());
        menu.addSeparator();
        auto *del = menu.addAction(tr("Delete Workspace"), this, [this, id] { deleteWorkspace(id); });
        del->setEnabled(m_store.workspaces.size() > 1);
    }
    menu.exec(m_tree->viewport()->mapToGlobal(pos));
}

void MainWindow::go(const QString &direction)
{
    QString error;
    if (m_store.go(direction, &error).isEmpty())
        statusBar()->showMessage(error, 2000);
}

void MainWindow::profileDialog(const char *slot)
{
    auto *part = m_panes.value(m_store.selected).main;
    if (!part || !QMetaObject::invokeMethod(part, slot, Q_ARG(QWidget *, this)))
        statusBar()->showMessage(tr("Open a session first"), 2000);
}

void MainWindow::showSettings()
{
    // agterm's Settings ▸ General subset that exists here so far
    QDialog dlg(this);
    dlg.setWindowTitle(tr("Configure agterm"));
    auto *form = new QFormLayout;
    Settings s = m_store.settings;

    auto *dirMode = new QComboBox;
    dirMode->addItem(tr("Home directory"), QStringLiteral("home"));
    dirMode->addItem(tr("Workspace folder"), QStringLiteral("workspace"));
    dirMode->addItem(tr("Fixed folder"), QStringLiteral("custom"));
    dirMode->setCurrentIndex(dirMode->findData(s.newSessionDirectory));
    auto *custom = new QLineEdit(s.newSessionCustomDirectory);
    auto *browse = new QPushButton(QIcon::fromTheme(QStringLiteral("document-open-folder")), {});
    connect(browse, &QPushButton::clicked, &dlg, [&] {
        const QString d = QFileDialog::getExistingDirectory(&dlg, tr("Folder for new sessions"), custom->text().isEmpty() ? QDir::homePath() : custom->text());
        if (!d.isEmpty())
            custom->setText(d);
    });
    auto *customRow = new QHBoxLayout;
    customRow->addWidget(custom, 1);
    customRow->addWidget(browse);
    auto syncCustom = [&] {
        const bool on = dirMode->currentData() == QLatin1String("custom");
        custom->setEnabled(on);
        browse->setEnabled(on);
    };
    connect(dirMode, &QComboBox::currentIndexChanged, &dlg, syncCustom);
    syncCustom();

    auto *placement = new QComboBox;
    placement->addItem(tr("At the end of the workspace"), QStringLiteral("end"));
    placement->addItem(tr("After the current session"), QStringLiteral("afterCurrent"));
    placement->setCurrentIndex(placement->findData(s.newSessionPlacement));
    auto *reset = new QComboBox;
    reset->addItem(tr("On the first key"), QStringLiteral("firstKey"));
    reset->addItem(tr("On Enter"), QStringLiteral("enter"));
    reset->addItem(tr("Never"), QStringLiteral("never"));
    reset->setCurrentIndex(reset->findData(s.statusReset));
    auto *confirm = new QCheckBox(tr("Ask before closing a session"));
    confirm->setChecked(s.confirmCloseSession);

    form->addRow(tr("New sessions open in:"), dirMode);
    form->addRow(QString(), customRow);
    form->addRow(tr("New sessions are added:"), placement);
    form->addRow(tr("Typing clears blocked/done status:"), reset);
    form->addRow(QString(), confirm);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    connect(buttons, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, &dlg, &QDialog::reject);
    auto *col = new QVBoxLayout(&dlg);
    col->addLayout(form);
    col->addWidget(buttons);
    if (dlg.exec() != QDialog::Accepted)
        return;
    s.newSessionDirectory = dirMode->currentData().toString();
    s.newSessionCustomDirectory = custom->text();
    s.newSessionPlacement = placement->currentData().toString();
    s.statusReset = reset->currentData().toString();
    s.confirmCloseSession = confirm->isChecked();
    m_store.setSettings(s);
}

void MainWindow::save()
{
    // Konsole signals directory changes only for a shown pane; /proc is authoritative for the rest
    for (auto *s : m_store.allSessions())
        if (const QString cwd = liveCwd(s->id); !cwd.isEmpty())
            m_store.workspaceOf(s->id)->folder = s->cwd = cwd;
    QJsonObject root = m_store.toJson();
    QJsonArray collapsed;
    for (const auto &c : std::as_const(m_tree->m_collapsed))
        collapsed << c;
    root.insert("window", QJsonObject{{"geometry", QString::fromLatin1(saveGeometry().toBase64())},
                                      {"splitter", QString::fromLatin1(m_split->saveState().toBase64())},
                                      {"sidebar", m_sidebarAction->isChecked()},
                                      {"flaggedView", m_tree->flaggedView()},
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
    for (const Panes &p : std::as_const(m_panes))
        delete p.view; // its parts go with their widgets
    delete m_quick;
    // a still-running PATH probe would emit finished() into our destroyed members when ~QObject kills it
    for (auto *proc : findChildren<QProcess *>()) {
        proc->disconnect(this);
        delete proc;
    }
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
    if (watched == m_quick && event->type() == QEvent::WindowDeactivate && !m_quickPinned)
        m_quick->hide(); // a click away dismisses it, unless a script opened it
    if (event->type() == QEvent::MouseButtonDblClick && watched->property("agtermSession").isValid()) {
        const QString id = watched->property("agtermSession").toString();
        if (Session *s = m_store.session(id)) {
            s->splitRatio = 0.5; // a double-click on the divider returns to an even split
            applyLayout(id);
            m_saveTimer.start();
        }
        return true;
    }
    if (event->type() == QEvent::KeyPress && !m_quitting) {
        auto *w = qobject_cast<QWidget *>(watched);
        auto *key = static_cast<QKeyEvent *>(event);
        if (w && m_stack->isAncestorOf(w) && !isOwnShortcut(key) && !key->isAutoRepeat()) {
            const bool interrupt = key->key() == Qt::Key_Escape || (key->key() == Qt::Key_C && key->modifiers() == Qt::ControlModifier);
            const bool submit = (key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter) && !(key->modifiers() & ~Qt::KeypadModifier);
            m_store.keyPressed(m_store.selected, interrupt ? Store::Key::Interrupt : submit ? Store::Key::Submit : Store::Key::Plain);
        }
    }
    return QMainWindow::eventFilter(watched, event);
}
