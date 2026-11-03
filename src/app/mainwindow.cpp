#include "mainwindow.h"

#include "paths.h"
#include "sidebardelegate.h"
#include "store.h"
#include "theme.h"

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
#include <QFontDatabase>
#include <QHBoxLayout>
#include <QPushButton>
#include <QToolButton>
#include <QVBoxLayout>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLabel>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QSaveFile>
#include <QScrollBar>
#include <QSplitter>
#include <QStackedWidget>
#include <QStatusBar>
#include <QTreeWidget>

namespace {
constexpr int IdRole = SidebarRole::Id, KindRole = SidebarRole::Kind;
constexpr int WorkspaceKind = SidebarRole::Workspace, SessionKind = SidebarRole::Session;
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
    m_tree = new SidebarView;
    m_tree->setHeaderHidden(true);
    m_tree->setRootIsDecorated(false);
    m_tree->setIndentation(0);
    m_tree->setItemDelegate(m_delegate = new SidebarDelegate(m_tree));
    m_tree->setMouseTracking(true);
    m_tree->setFrameShape(QFrame::NoFrame);
    m_tree->setExpandsOnDoubleClick(false);
    m_tree->setContextMenuPolicy(Qt::CustomContextMenu);
    m_tree->setFocusPolicy(Qt::NoFocus); // keyboard stays in the terminal
    m_tree->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);

    // sidebar: title row with + and the main menu, the tree, a socket status footer
    auto *title = new QLabel(tr("Sessions"));
    QFont tf = title->font();
    tf.setWeight(QFont::DemiBold);
    tf.setPointSizeF(tf.pointSizeF() * 1.08);
    title->setFont(tf);
    auto toolButton = [](const QString &icon, const QString &tip) {
        auto *b = new QToolButton;
        b->setIcon(QIcon::fromTheme(icon));
        b->setToolTip(tip);
        b->setAccessibleName(tip);
        b->setAutoRaise(true);
        b->setFocusPolicy(Qt::NoFocus);
        return b;
    };
    auto *add = toolButton(QStringLiteral("list-add"), tr("New Session (Ctrl+Shift+T)"));
    connect(add, &QToolButton::clicked, this, [this] { QString e; newSession(m_store.resolveWorkspace({}, &e)); });
    m_menuButton = toolButton(QStringLiteral("application-menu"), tr("Main Menu"));
    m_menuButton->setPopupMode(QToolButton::InstantPopup);
    auto *titleRow = new QHBoxLayout;
    titleRow->setContentsMargins(14, 8, 8, 6);
    titleRow->addWidget(title, 1);
    titleRow->addWidget(add);
    titleRow->addWidget(m_menuButton);

    m_socketDot = new QLabel;
    m_socketDot->setFixedSize(7, 7);
    m_socketText = new QLabel;
    auto *hint = new QLabel(tr("Ctrl+Alt+↓ attention"));
    hint->setToolTip(tr("Jump to the next session that needs you"));
    m_footer = new QWidget;
    auto *footerRow = new QHBoxLayout(m_footer);
    footerRow->setContentsMargins(12, 7, 12, 8);
    footerRow->setSpacing(8);
    footerRow->addWidget(m_socketDot);
    footerRow->addWidget(m_socketText, 1);
    footerRow->addWidget(hint);
    m_footerLabels = {m_socketText, hint};

    m_sidebar = new QWidget;
    m_sidebar->setObjectName(QStringLiteral("sidebar"));
    auto *side = new QVBoxLayout(m_sidebar);
    side->setContentsMargins(0, 0, 0, 0);
    side->setSpacing(0);
    side->addLayout(titleRow);
    side->addWidget(m_tree, 1);
    side->addWidget(m_footer);

    // session header: workspace › session, status chip, cwd, foreground process
    m_crumbWs = new QLabel;
    m_crumbSep = new QLabel(QStringLiteral("›"));
    m_crumbName = new QLabel;
    QFont nf = m_crumbName->font();
    nf.setWeight(QFont::DemiBold);
    m_crumbName->setFont(nf);
    m_statusChip = new QLabel;
    m_cwdLabel = new QLabel;
    m_cwdLabel->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    m_cwdLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_procChip = new QLabel;
    m_procChip->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    m_header = new QWidget;
    m_header->setObjectName(QStringLiteral("header"));
    auto *headerRow = new QHBoxLayout(m_header);
    headerRow->setContentsMargins(14, 7, 14, 7);
    headerRow->setSpacing(10);
    for (QWidget *w : {m_crumbWs, m_crumbSep, m_crumbName, m_statusChip})
        headerRow->addWidget(w);
    headerRow->addStretch(1);
    headerRow->addWidget(m_cwdLabel);
    headerRow->addWidget(m_procChip);

    m_stack = new QStackedWidget;
    m_empty = new QWidget;
    auto *emptyCol = new QVBoxLayout(m_empty);
    emptyCol->addStretch(1);
    auto *emptyIcon = new QLabel;
    emptyIcon->setPixmap(QIcon::fromTheme(QStringLiteral("utilities-terminal")).pixmap(64));
    auto *emptyTitle = new QLabel(tr("No sessions"));
    emptyTitle->setFont(tf);
    auto *emptyHint = new QLabel(tr("Open a shell, or let an agent create one with agtermctl."));
    auto *emptyButton = new QPushButton(QIcon::fromTheme(QStringLiteral("list-add")), tr("New Session"));
    connect(emptyButton, &QPushButton::clicked, add, &QToolButton::click);
    for (QWidget *w : {static_cast<QWidget *>(emptyIcon), static_cast<QWidget *>(emptyTitle), static_cast<QWidget *>(emptyHint),
                       static_cast<QWidget *>(emptyButton)})
        emptyCol->addWidget(w, 0, Qt::AlignHCenter);
    emptyCol->addStretch(1);
    m_stack->addWidget(m_empty);

    auto *content = new QWidget;
    auto *contentCol = new QVBoxLayout(content);
    contentCol->setContentsMargins(0, 0, 0, 0);
    contentCol->setSpacing(0);
    contentCol->addWidget(m_header);
    contentCol->addWidget(m_stack, 1);

    m_split = new QSplitter;
    m_split->setHandleWidth(1);
    m_split->setChildrenCollapsible(false);
    m_split->addWidget(m_sidebar);
    m_split->addWidget(content);
    m_split->setStretchFactor(1, 1);
    m_split->setSizes({264, 940});
    m_sidebar->setMinimumWidth(180);
    setCentralWidget(m_split);
    resize(1280, 800);

    createActions();
    applyTheme();

    // the active-status ring spins only while some session is working
    m_spinTimer.setInterval(50);
    connect(&m_spinTimer, &QTimer::timeout, this, [this] {
        m_delegate->spinnerPhase = (m_delegate->spinnerPhase + 18) % 360;
        m_tree->viewport()->update();
    });
    // cwd and foreground process have no change signal for background panes; poll the shown one
    m_headerTimer.setInterval(1000);
    connect(&m_headerTimer, &QTimer::timeout, this, &MainWindow::updateHeader);
    m_headerTimer.start();

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
    connect(m_tree, &QTreeWidget::itemClicked, this, [this](QTreeWidgetItem *item) {
        if (item->data(0, KindRole).toInt() != WorkspaceKind)
            return;
        const QString id = item->data(0, IdRole).toString();
        m_collapsed.contains(id) ? m_collapsed.remove(id) : (m_collapsed.insert(id), true);
        item->setExpanded(!m_collapsed.contains(id));
        item->setData(0, SidebarRole::Expanded, item->isExpanded());
        m_saveTimer.start();
    });
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
        [this] { m_sidebar->setVisible(m_sidebar->isHidden()); m_saveTimer.start(); });
    add(view, tr("Show &Menu Bar"), QKeySequence(QStringLiteral("Ctrl+Shift+M")), QStringLiteral("show-menu"),
        [this] { menuBar()->setVisible(!menuBar()->isVisible()); m_saveTimer.start(); });

    auto *settings = menuBar()->addMenu(tr("Se&ttings"));
    add(settings, tr("&Edit Current Profile…"), {}, QStringLiteral("document-edit"), [this] { profileDialog("showEditCurrentProfileDialog"); });
    add(settings, tr("&Manage Profiles…"), {}, QStringLiteral("configure"), [this] { profileDialog("showManageProfilesDialog"); });

    // the menu bar starts hidden, KDE-style; the same menus live behind the sidebar's menu button
    auto *hamburger = new QMenu(this);
    for (QAction *a : menuBar()->actions())
        hamburger->addAction(a);
    m_menuButton->setMenu(hamburger);
}

void MainWindow::applyTheme()
{
    const Theme t = Theme::from(palette());
    m_sidebar->setStyleSheet(QStringLiteral("#sidebar{background:%1;} QTreeView{background:transparent;}").arg(Theme::css(t.sidebar)));
    m_footer->setStyleSheet(QStringLiteral("QWidget{border-top:1px solid %1;} QLabel{border:none;}").arg(Theme::css(t.line)));
    for (QLabel *l : m_footerLabels) {
        QFont f = font();
        f.setPointSizeF(f.pointSizeF() * 0.85);
        l->setFont(f);
        l->setStyleSheet(QStringLiteral("color:%1;").arg(Theme::css(t.faint)));
    }
    m_header->setStyleSheet(QStringLiteral("#header{background:%1; border-bottom:1px solid %2;}").arg(Theme::css(t.window), Theme::css(t.line)));
    m_crumbWs->setStyleSheet(QStringLiteral("color:%1;").arg(Theme::css(t.dim)));
    m_crumbSep->setStyleSheet(QStringLiteral("color:%1;").arg(Theme::css(t.faint)));
    m_cwdLabel->setStyleSheet(QStringLiteral("color:%1;").arg(Theme::css(t.dim)));
    m_procChip->setStyleSheet(QStringLiteral("color:%1; background:%2; border-radius:5px; padding:1px 7px;")
                                  .arg(Theme::css(t.dim), Theme::css(Theme::alpha(t.text, 22))));
    m_split->setStyleSheet(QStringLiteral("QSplitter::handle{background:%1;}").arg(Theme::css(t.line)));
    setSocketStatus(m_socketOk, m_socketError);
    updateHeader();
}

void MainWindow::setSocketStatus(bool ok, const QString &error)
{
    m_socketOk = ok;
    m_socketError = error;
    const Theme t = Theme::from(palette());
    m_socketDot->setStyleSheet(QStringLiteral("background:%1; border-radius:3px;").arg(Theme::css(ok ? t.ok : t.warn)));
    m_socketText->setText(ok ? tr("Socket ready") : tr("Socket unavailable"));
    m_socketText->setToolTip(ok ? socketPath() : error);
}

void MainWindow::updateHeader()
{
    const Session *s = m_store.session(m_store.selected);
    m_header->setVisible(s);
    if (!s)
        return;
    const Theme t = Theme::from(palette());
    m_crumbWs->setText(m_store.workspaceOf(s->id)->name);
    m_crumbName->setText(s->name);
    const QColor c = s->status == QLatin1String("idle") ? t.dim : t.statusColor(s->status);
    m_statusChip->setText(Theme::statusPhrase(s->status));
    m_statusChip->setStyleSheet(QStringLiteral("color:%1; background:%2; border-radius:9px; padding:1px 8px; font-weight:500;")
                                    .arg(Theme::css(c), Theme::css(Theme::alpha(c, s->status == QLatin1String("idle") ? 26 : 46))));
    const QString cwd = liveCwd(s->id);
    m_cwdLabel->setText(shortPath(cwd.isEmpty() ? s->cwd : cwd));
    const QString fg = terminal(s->id) ? terminal(s->id)->foregroundProcessName() : QString();
    m_procChip->setText(fg);
    m_procChip->setVisible(!fg.isEmpty());
}

void MainWindow::changeEvent(QEvent *event)
{
    if (event->type() == QEvent::PaletteChange && m_header)
        applyTheme();
    QMainWindow::changeEvent(event);
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
    m_sidebar->setVisible(window.value("sidebar").toBool(true));
    menuBar()->setVisible(window.value("menubar").toBool(false));
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
    const int scroll = m_tree->verticalScrollBar()->value();
    m_tree->clear();
    bool anyActive = false;
    for (const auto &w : m_store.workspaces) {
        auto *wi = new QTreeWidgetItem(m_tree, {w.name});
        wi->setData(0, IdRole, w.id);
        wi->setData(0, KindRole, WorkspaceKind);
        wi->setFlags(Qt::ItemIsEnabled);
        int attention = 0;
        for (const auto &s : w.sessions) {
            auto *si = new QTreeWidgetItem(wi, {s.name});
            si->setData(0, IdRole, s.id);
            si->setData(0, KindRole, SessionKind);
            si->setData(0, SidebarRole::Status, s.status);
            si->setData(0, SidebarRole::Sub, s.status == QLatin1String("idle") ? shortPath(s.cwd) : Theme::statusPhrase(s.status));
            si->setToolTip(0, QStringLiteral("%1\n%2").arg(s.title, shortPath(s.cwd)));
            attention += s.status == QLatin1String("blocked") || s.status == QLatin1String("completed");
            anyActive |= s.status == QLatin1String("active");
        }
        wi->setData(0, SidebarRole::Count, int(w.sessions.size()));
        wi->setData(0, SidebarRole::Attention, attention);
        wi->setExpanded(!m_collapsed.contains(w.id));
        wi->setData(0, SidebarRole::Expanded, wi->isExpanded());
        for (int i = 0; i < wi->childCount(); ++i)
            if (wi->child(i)->data(0, IdRole).toString() == m_store.selected)
                m_tree->setCurrentItem(wi->child(i));
    }
    m_tree->verticalScrollBar()->setValue(scroll);
    anyActive ? m_spinTimer.start() : m_spinTimer.stop();
    m_rebuilding = false;
    updateHeader();
}

void MainWindow::showSelected()
{
    const Session *s = m_store.session(m_store.selected);
    auto *part = m_parts.value(m_store.selected);
    m_stack->setCurrentWidget(part ? part->widget() : m_empty);
    if (part && part->widget()->window()->isActiveWindow())
        part->widget()->setFocus();
    setWindowTitle(s ? QStringLiteral("%1 / %2").arg(m_store.workspaceOf(s->id)->name, s->name) : QString());
    updateHeader();
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
                                      {"sidebar", !m_sidebar->isHidden()},
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
