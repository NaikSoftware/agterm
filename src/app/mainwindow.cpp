#include "mainwindow.h"

#include "filepanel.h"
#include "launcher.h"
#include "palette.h"
#include "paths.h"
#include "sidebar.h"
#include "store.h"

#include <KActionCollection>
#include <KNotification>
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
#include <QPainter>
#include <QProcess>
#include <QSet>
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
    // Konsole's part presets override = true (the terminal keeps every key); false hands ours to the window
    if (m_window->isOwnShortcut(event))
        override = false;
}

MainWindow::MainWindow(Store &store, const QString &statePath)
    : m_store(store), m_statePath(statePath)
{
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
    m_filterButton = footerButton({}, tr("Toggle Workspace Filter"));
    connect(m_filterButton, &QToolButton::clicked, this, [this] { m_store.setFilter(!m_store.focusEnabled); });
    footer->addWidget(m_filterButton);
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
    m_filePanel = new FilePanel;
    m_filePanel->setMinimumWidth(160);
    m_filePanel->setMaximumWidth(560);
    m_filePanel->hide();
    connect(m_filePanel, &FilePanel::companionRequested, this, [this](const QString &dir) {
        if (m_store.session(m_store.selected))
            m_store.select(m_store.addCompanion(m_store.selected, {}, dir));
    });
    m_split->addWidget(m_sidebarPanel);
    m_split->addWidget(m_filePanel); // agterm's file panel sits right of the sidebar
    m_split->addWidget(m_stack);
    m_split->setStretchFactor(2, 1);
    m_split->setSizes({230, 240, 970});
    connect(m_split, &QSplitter::splitterMoved, this, [this] {
        if (!m_filePanel->isHidden() && m_split->sizes().value(1) > 0) {
            m_filePanelWidth = m_split->sizes().value(1); // a dragged divider is the new width
            m_saveTimer.start();
        }
    });
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
    strip->addAction(chromeIcon(QStringLiteral("filepanel"), ink), tr("Toggle File Panel"), m_actions.value(QStringLiteral("toggle_file_panel")),
                     &QAction::trigger);
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
    strip->addAction(chromeIcon(QStringLiteral("split"), ink), tr("Split"), m_actions.value(QStringLiteral("toggle_split")), &QAction::trigger);
    addToolBar(Qt::TopToolBarArea, strip);
    m_strip = strip;

    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(500);
    connect(&m_saveTimer, &QTimer::timeout, this, &MainWindow::save);
    m_agentTimer.setInterval(2000);
    connect(&m_agentTimer, &QTimer::timeout, this, &MainWindow::sampleAgents);
    m_agentTimer.start();

    connect(&m_store, &Store::changed, this, [this] {
        syncFilterButton();
        m_actions.value(QStringLiteral("undo_close"))->setEnabled(!m_store.pending.isEmpty());
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
    connect(&m_store, &Store::notified, this, [this](const QString &id, const QString &title, const QString &body) {
        const Session *s = m_store.session(id);
        if (!s || (isActiveWindow() && id == m_store.selected))
            return; // already in front of you
        m_store.setUnseen(id, s->unseen + 1);
        auto *n = KNotification::event(KNotification::Notification, title.isEmpty() ? s->displayName() : title, body,
                                       QStringLiteral("agterm-qt"));
        connect(n->addDefaultAction(tr("Show")), &KNotificationAction::activated, this, [this, id] {
            m_store.select(id); // the banner brings the window forward on the session that raised it
            show();
            raise();
            activateWindow();
        });
    });
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
    // ⌘Z: the newest close inside its grace comes back with its shells; enabled only then, so Redo keeps the chord otherwise
    QAction *undo = action(QStringLiteral("undo_close"), tr("Reopen Closed Item"), QStringLiteral("edit-undo"),
                           QKeySequence(QStringLiteral("Ctrl+Shift+Z")), [this] { m_store.undoClose(); });
    undo->setEnabled(false);
    file->addAction(undo);
    file->addAction(action(QStringLiteral("reopen_recent"), tr("Reopen Last Closed Item"), QStringLiteral("edit-undo"),
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
    session->addAction(action(QStringLiteral("new_companion"), tr("New Companion"), QStringLiteral("list-add"), {},
                              [this] { newCompanion(m_store.selected); }));
    session->addAction(action(QStringLiteral("duplicate_companion"), tr("Duplicate as Companion"), QStringLiteral("edit-copy"), {}, [this] {
        if (m_store.session(m_store.selected))
            duplicateCompanion(m_store.selected);
    }));
    session->addAction(action(QStringLiteral("clear_status"), tr("Clear Status"), QStringLiteral("edit-clear"), {},
                              [this] { m_store.setStatus(m_store.selected, QStringLiteral("idle")); }));
    session->addAction(action(QStringLiteral("toggle_flag"), tr("Flag"), QStringLiteral("flag"), QKeySequence(QStringLiteral("Ctrl+Alt+Shift+F")), [this] {
        if (const Session *s = m_store.session(m_store.selected))
            m_store.setFlag(s->id, !s->flagged);
    }));
    // palette-only, as in agterm: "Tint Session: Red" … "Tint Session: None" for the active session
    for (const QString &c : Store::tintColors + QStringList{QString()})
        action(QStringLiteral("tint_session_") + (c.isEmpty() ? QStringLiteral("none") : c),
               tr("Tint Session: %1").arg(c.isEmpty() ? tr("None") : c.left(1).toUpper() + c.mid(1)), {}, {},
               [this, c] { m_store.setTint(m_store.selected, c); });

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
    view->addAction(action(QStringLiteral("toggle_file_panel"), tr("Show File Panel"), QStringLiteral("folder"),
                           QKeySequence(QStringLiteral("Ctrl+Alt+Shift+E")), [this] { QString e; filePanel(QStringLiteral("toggle"), 0, &e); }));
    auto *flagged = action(QStringLiteral("toggle_flagged_view"), tr("Flagged Sessions"), QStringLiteral("flag"), {},
                           [this] { m_flagButton->setChecked(m_actions.value(QStringLiteral("toggle_flagged_view"))->isChecked()); });
    flagged->setCheckable(true);
    view->addAction(flagged);
    view->addAction(action(QStringLiteral("focus_workspace"), tr("Focus Workspace"), {}, {}, [this] {
        QString e;
        if (const QString ws = m_store.resolveWorkspace({}, &e); !ws.isEmpty())
            m_store.focusWorkspace(ws, QStringLiteral("toggle"));
    }));
    view->addAction(action(QStringLiteral("toggle_workspace_filter"), tr("Toggle Workspace Filter"), {}, {},
                           [this] { m_store.setFilter(!m_store.focusEnabled); }));
    view->addAction(action(QStringLiteral("clear_focus"), tr("Clear Focus"), {}, {}, [this] {
        for (const QString &id : QStringList(m_store.focused))
            m_store.focusWorkspace(id, QStringLiteral("off"));
    }));
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
    view->addSeparator();
    view->addAction(action(QStringLiteral("toggle_terminal_zoom"), tr("Terminal Zoom"), QStringLiteral("zoom-fit-best"),
                           QKeySequence(QStringLiteral("Ctrl+Alt+Shift+Return")), [this] { toggleZoom(); }));
    view->addAction(action(QStringLiteral("toggle_fullscreen"), tr("Full Screen"), QStringLiteral("view-fullscreen"), QKeySequence(QStringLiteral("F11")),
                           [this] { setWindowState(windowState() ^ Qt::WindowFullScreen); }));

    auto *nav = menuBar()->addMenu(tr("&Navigate"));
    m_palette = new Palette(this);
    auto sessionItems = [this](bool byRecency) {
        QList<Palette::Item> items;
        QList<Session *> all = m_store.navigableSessions(); // the palettes stay inside the flagged view or the filter
        if (byRecency) {
            std::stable_sort(all.begin(), all.end(), [this](Session *a, Session *b) {
                const qsizetype ia = m_store.recent.indexOf(a->id), ib = m_store.recent.indexOf(b->id);
                return (ia < 0 ? 1 << 30 : ia) < (ib < 0 ? 1 << 30 : ib);
            });
        } else {
            std::stable_sort(all.begin(), all.end(), [](Session *a, Session *b) { return a->displayName().compare(b->displayName(), Qt::CaseInsensitive) < 0; });
        }
        for (Session *s : all)
            items.append({s->displayName(), m_store.workspaceOf(s->id)->name + QStringLiteral(" · ") + s->cwd, [this, id = s->id] { m_store.select(id); }});
        return items;
    };
    nav->addAction(action(QStringLiteral("session_palette"), tr("Go to Session…"), QStringLiteral("search"), QKeySequence(QStringLiteral("Ctrl+P")),
                          [this, sessionItems] { m_palette->open(tr("Go to session…"), sessionItems(false)); }));
    nav->addAction(action(QStringLiteral("command_palette"), tr("Action Palette…"), QStringLiteral("run-build"), QKeySequence(QStringLiteral("Ctrl+Shift+P")), [this] {
        QList<Palette::Item> items;
        for (QAction *a : actions())
            if (!a->text().isEmpty() && a != m_actions.value(QStringLiteral("command_palette")))
                items.append({a->text().remove(QLatin1Char('&')).remove(QStringLiteral("…")), a->shortcut().toString(QKeySequence::NativeText), [a] { a->trigger(); },
                              a->isEnabled()});
        m_palette->open(tr("Run an action…"), items);
    }));
    nav->addAction(action(QStringLiteral("mru_switcher"), tr("Switch to Recent Session"), {}, QKeySequence(QStringLiteral("Ctrl+Tab")), [this, sessionItems] {
        m_palette->switching() ? m_palette->step(1) : m_palette->open({}, sessionItems(true), true);
    }));
    nav->addAction(action(QStringLiteral("mru_switcher_back"), tr("Switch to Recent Session (Reverse)"), {}, QKeySequence(QStringLiteral("Ctrl+Shift+Backtab")),
                          [this, sessionItems] {
                              if (!m_palette->switching())
                                  m_palette->open({}, sessionItems(true), true);
                              m_palette->step(-1);
                          }));
    nav->addSeparator();
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
        if (a->isEnabled() && !a->shortcut().isEmpty() && a->shortcut().matches(key) == QKeySequence::ExactMatch)
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
    m_filePanelWidth = qBound(160, window.value("filePanelWidth").toInt(240), 560);
    m_filePanel->setVisible(window.value("filePanel").toBool(false));
    applyFilePanelWidth();
    syncFilterButton();
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
        connect(part, &KParts::Part::setWindowCaption, this, [this, id, part](const QString &title) {
            // a title set by a running program (an agent naming its task) renames the session; the one a shell
            // prompt sets on every line (bash's user@host: dir) does not
            auto *t = qobject_cast<TerminalInterface *>(part);
            const int fg = t->foregroundProcessId();
            if (fg > 0 && fg != t->terminalProcessId() && !title.trimmed().isEmpty())
                m_store.setTitle(id, title);
        });
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
    // Konsole's own actions (close-session on Ctrl+Shift+W, …) would make our chords ambiguous, and an
    // ambiguous shortcut fires neither, so the window's keys win
    QSet<QKeySequence> ours;
    for (const QAction *a : actions())
        for (const QKeySequence &k : a->shortcuts())
            ours << k;
    for (KActionCollection *col : KActionCollection::allCollections())
        for (QAction *a : col->actions()) {
            QList<QKeySequence> keep = a->shortcuts();
            if (keep.removeIf([&ours](const QKeySequence &k) { return ours.contains(k); }) > 0)
                a->setShortcuts(keep);
        }
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
    if (QObject *ks = konsoleSession(id))
        for (int context : {0, 1}) // local and remote: caption = the title the program set (%w), not "dir : process"
            QMetaObject::invokeMethod(ks, "setTabTitleFormat", Q_ARG(int, context), Q_ARG(QString, QStringLiteral("%w")));
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
        const QString cwd = !s->splitCwd.isEmpty() ? s->splitCwd : liveCwd(id).isEmpty() ? s->cwd : liveCwd(id);
        p.right = spawnPart(id, QStringLiteral("right"), cwd, std::exchange(s->splitCommand, {}), p.split);
        s->splitCwd.clear();
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
    p.layers->setCurrentWidget(p.split);
    if (KParts::ReadOnlyPart *target = p.main; target && id == m_store.selected && isActiveWindow())
        target->widget()->setFocus();
}

void MainWindow::paneExited(const QString &id, KParts::ReadOnlyPart *part)
{
    if (!m_panes.contains(id))
        return;
    Panes &p = m_panes[id];
    if (!m_store.session(id)) { // closed and inside its undo grace: an undo brings back what is left
        p.main = p.main == part ? nullptr : p.main;
        p.right = p.right == part ? nullptr : p.right;
        return;
    }
    if (part == p.right) {
        p.right = nullptr;
        m_store.setSplit(id, false, false, m_store.session(id)->splitAxis);
    } else if (part == p.main) {
        p.main = nullptr;
        m_sessions.remove(id);
        if (p.right) { // the split survivor becomes the session's only shell
            p.main = std::exchange(p.right, nullptr);
            p.main->widget()->show();
            m_store.setSplit(id, false, false, m_store.session(id)->splitAxis);
        } else if (!m_store.companionsOf(id).isEmpty() && m_respawned.value(id).msecsTo(QDateTime::currentDateTime()) > 2000) {
            // a parent with companions gets a fresh shell; one that exits again within 2 s closes the group
            m_respawned.insert(id, QDateTime::currentDateTime());
            const Session *s = m_store.session(id);
            p.main = spawnPart(id, QStringLiteral("main"), s->cwd, {}, p.split);
            if (p.main) {
                p.split->insertWidget(0, p.main->widget());
                if (id == m_store.selected)
                    p.main->widget()->setFocus();
            }
        } else {
            m_store.removeSession(id);
        }
    }
}

void MainWindow::newCompanion(const QString &parentId)
{
    if (m_store.session(parentId))
        m_store.select(m_store.addCompanion(parentId, {}, liveCwd(parentId)));
}

void MainWindow::duplicateCompanion(const QString &id)
{
    QString error;
    const QString copy = duplicateAsCompanion(m_store, *this, id, &error);
    copy.isEmpty() ? statusBar()->showMessage(error, 5000) : m_store.select(copy);
}

bool MainWindow::panePlan(const QString &sessionId, const QString &pane, PanePlan *out, QString *error)
{
    // a shell holding the pane gives a plain shell in its directory; anything else is run again as it was started
    const Panes p = m_panes.value(sessionId);
    auto *t = qobject_cast<TerminalInterface *>(pane == QLatin1String("right") ? p.right : p.main);
    const QString name = pane == QLatin1String("right") ? QStringLiteral("right") : QStringLiteral("left");
    if (!t || t->terminalProcessId() <= 0) {
        *error = QStringLiteral("%1 pane is not realized; nothing was created").arg(name);
        return false;
    }
    const int shell = t->terminalProcessId(), fg = t->foregroundProcessId();
    const int pid = fg > 0 ? fg : shell;
    out->cwd = QFile::symLinkTarget(QStringLiteral("/proc/%1/cwd").arg(pid));
    out->command.clear();
    if (pid == shell)
        return !out->cwd.isEmpty() || (*error = QStringLiteral("%1 pane: its directory cannot be read; nothing was created").arg(name), false);
    QFile f(QStringLiteral("/proc/%1/cmdline").arg(pid));
    const QStringList argv = f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()).split(QChar(0), Qt::SkipEmptyParts) : QStringList();
    if (argv.isEmpty() || out->cwd.isEmpty()) {
        *error = QStringLiteral("%1 pane: the foreground program cannot be read; nothing was created").arg(name);
        return false;
    }
    // shortcut: the source session's id in the arguments is not rebound to the copy's, as master does
    QStringList quoted;
    for (QString a : argv)
        quoted << QLatin1Char('\'') + a.replace(QLatin1Char('\''), QStringLiteral("'\\''")) + QLatin1Char('\'');
    out->command = QStringLiteral("exec ") + quoted.join(QLatin1Char(' '));
    return true;
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

void MainWindow::applyFilePanelWidth()
{
    // the splitter would otherwise hand a newly shown panel whatever share it computes
    if (m_filePanel->isHidden())
        return;
    QList<int> sizes = m_split->sizes();
    sizes[2] = qMax(200, sizes[2] + sizes[1] - m_filePanelWidth);
    sizes[1] = m_filePanelWidth;
    m_split->setSizes(sizes);
}

bool MainWindow::filePanel(const QString &mode, int width, QString *)
{
    if (!mode.isEmpty())
        m_filePanel->setVisible(mode == QLatin1String("toggle") ? m_filePanel->isHidden() : mode == QLatin1String("show"));
    if (width > 0)
        m_filePanelWidth = qBound(160, width, 560); // agterm's clamp
    applyFilePanelWidth();
    m_filePanel->setRoot(liveCwd(m_store.selected));
    m_saveTimer.start();
    return true;
}

QJsonObject MainWindow::chromeState() const
{
    return {{"sidebarVisible", !m_sidebarPanel->isHidden()},
            {"filePanel", QJsonObject{{"visible", !m_filePanel->isHidden()}, {"width", m_filePanelWidth}}}};
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
        KParts::ReadOnlyPart *front = p.main;
        if (front)
            front->widget()->setFocus();
    }
    m_shownId = m_store.selected;
    if (!m_filePanel->isHidden())
        m_filePanel->setRoot(liveCwd(m_store.selected)); // no-op while the folder is unchanged
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
    if (!m_filePanel->isHidden()) // a cd in the active session moves the file panel with it
        m_filePanel->setRoot(liveCwd(m_store.selected));
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
    if (!m_store.settings.closeUndo || !m_store.softClose(live))
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
    if (!m_store.settings.closeUndo || !m_store.softRemoveWorkspace(id))
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

void MainWindow::syncFilterButton()
{
    // dimmed while nothing is marked: there is nothing to filter to
    const QColor ink = palette().color(QPalette::WindowText);
    m_filterButton->setIcon(chromeIcon(m_store.focusEnabled ? QStringLiteral("gridFilled") : QStringLiteral("grid"), ink));
    m_filterButton->setEnabled(!m_store.focused.isEmpty());
    m_filterButton->setToolTip(m_store.focusEnabled ? tr("Show all workspaces") : tr("Show only focused workspaces"));
    QString e;
    m_actions.value(QStringLiteral("focus_workspace"))->setText(m_store.isSoleFocus(m_store.resolveWorkspace({}, &e)) ? tr("Unfocus Workspace") : tr("Focus Workspace"));
    m_actions.value(QStringLiteral("toggle_workspace_filter"))->setEnabled(!m_store.focused.isEmpty());
    m_actions.value(QStringLiteral("clear_focus"))->setEnabled(!m_store.focused.isEmpty());
}

void MainWindow::fillTintMenu(QMenu *menu, const QStringList &ids)
{
    // a choice is checked only when every target shares it; the placements act only on tinted rows
    QSet<QString> colors;
    QSet<QStringList> placements;
    bool allTinted = true;
    for (const QString &id : ids) {
        const Tint t = m_store.session(id) ? m_store.session(id)->tint : m_store.workspace(id)->tint;
        colors << t.color;
        placements << t.on;
        allTinted &= !t.color.isEmpty();
    }
    auto add = [&](const QString &title, const QIcon &icon, bool checked, std::function<void(const QString &)> apply) {
        auto *a = menu->addAction(icon, title, this, [ids, apply] {
            for (const QString &id : ids)
                apply(id);
        });
        a->setCheckable(true);
        a->setChecked(checked);
        return a;
    };
    add(tr("None"), {}, colors == QSet<QString>{QString()}, [this](const QString &id) { m_store.setTint(id, {}); });
    for (const QString &c : Store::tintColors) {
        QPixmap swatch(24, 24);
        swatch.fill(Qt::transparent);
        QPainter p(&swatch);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen);
        p.setBrush(tintColor(c));
        p.drawEllipse(QRectF(2, 2, 20, 20));
        p.end();
        add(c.left(1).toUpper() + c.mid(1), QIcon(swatch), colors == QSet<QString>{c}, [this, c](const QString &id) { m_store.setTint(id, c); });
    }
    menu->addSection(tr("Show On"));
    const QList<std::pair<QString, QStringList>> options{{tr("Icon"), {QStringLiteral("icon")}},
                                                        {tr("Name"), {QStringLiteral("name")}},
                                                        {tr("Icon and Name"), {QStringLiteral("icon"), QStringLiteral("name")}}};
    for (const auto &[title, parts] : options)
        add(title, {}, allTinted && placements == QSet<QStringList>{parts}, [this, parts](const QString &id) { m_store.placeTint(id, parts); })
            ->setEnabled(allTinted);
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
            menu.addAction(tr("New Companion"), this, [this, id] { newCompanion(id); });
            menu.addAction(tr("Duplicate as Companion"), this, [this, id] { duplicateCompanion(id); });
        }
        fillMoveMenu(menu.addMenu(tr("Move to")), ids);
        bool allFlagged = true;
        for (const auto &sid : ids)
            allFlagged &= m_store.session(sid)->flagged;
        menu.addAction(allFlagged ? tr("Unflag") : tr("Flag"), this, [this, ids, allFlagged] {
            for (const auto &sid : ids)
                m_store.setFlag(sid, !allFlagged);
        });
        fillTintMenu(menu.addMenu(tr("Tint")), ids);
        menu.addAction(ids.size() == 1 ? tr("Close Session") : tr("Close %1 Sessions").arg(ids.size()), this, [this, ids] { closeSessions(ids); });
    } else {
        const Workspace *w = m_store.workspace(id);
        menu.addAction(QIcon::fromTheme(QStringLiteral("tab-new")), tr("New Session"), this, [this, id] { newSession(id); });
        menu.addSeparator();
        menu.addAction(m_store.isSoleFocus(id) ? tr("Unfocus") : tr("Focus"), this, [this, id] { m_store.focusWorkspace(id, QStringLiteral("toggle")); });
        const bool member = m_store.focused.contains(id);
        menu.addAction(member ? tr("Remove from Focus") : tr("Add to Focus"), this,
                       [this, id, member] { m_store.focusWorkspace(id, member ? QStringLiteral("off") : QStringLiteral("add")); });
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
        fillTintMenu(menu.addMenu(tr("Tint")), {id});
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
    auto *undoClose = new QCheckBox(tr("Allow undo after closing sessions and workspaces"));
    undoClose->setChecked(s.closeUndo);

    form->addRow(tr("New sessions open in:"), dirMode);
    form->addRow(QString(), customRow);
    form->addRow(tr("New sessions are added:"), placement);
    form->addRow(tr("Typing clears blocked/done status:"), reset);
    form->addRow(QString(), confirm);
    form->addRow(QString(), undoClose);
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
    s.closeUndo = undoClose->isChecked();
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
                                      {"filePanel", !m_filePanel->isHidden()},
                                      {"filePanelWidth", m_filePanelWidth},
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
    // a still-running PATH probe would emit finished() into our destroyed members when ~QObject kills it
    for (auto *proc : findChildren<QProcess *>()) {
        proc->disconnect(this);
        delete proc;
    }
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    m_saveTimer.stop();
    m_store.finalizePending(); // a close still inside its grace is final at quit
    save();
    m_quitting = true; // parts die with the window from here on; their sessions must stay saved
    QMainWindow::closeEvent(event);
}

bool MainWindow::eventFilter(QObject *watched, QEvent *event)
{
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
