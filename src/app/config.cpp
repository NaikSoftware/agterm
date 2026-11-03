// MainWindow's config side: keymap.conf, hooks.conf, the theme picker, appearance and terminal notifications.
#include "mainwindow.h"

#include "hooks.h"
#include "palette.h"
#include "paths.h"
#include "sidebar.h"
#include "store.h"

#include <KConfig>
#include <KConfigGroup>
#include <KNotification>
#include <KParts/ReadOnlyPart>
#include <KSharedConfig>
#include <kde_terminal_interface.h>

#include <QAction>
#include <QApplication>
#include <QClipboard>
#include <QDBusConnection>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QMenuBar>
#include <QProcess>
#include <QSplitter>
#include <QStandardPaths>
#include <QStatusBar>
#include <QToolBar>
#include <QWheelEvent>

#include <dlfcn.h>

static QString readText(const QString &path, QString *error)
{
    QFile f(path);
    if (f.open(QIODevice::ReadOnly))
        return QString::fromUtf8(f.readAll());
    if (f.exists())
        *error = f.errorString();
    return {};
}

static void writeIfMissing(const QString &path, const QString &text)
{
    if (QFile f(path); !f.exists() && f.open(QIODevice::WriteOnly))
        f.write(text.toUtf8());
}

QString MainWindow::configDir() const
{
    return configDirectory(m_store.settings.configDirectory, qEnvironmentVariable("AGTERM_STATE_DIR"), QDir::homePath());
}

void MainWindow::loadConfig()
{
    QDir().mkpath(configDir());
    writeIfMissing(configDir() + QStringLiteral("/keymap.conf"), starterKeymap(m_defaultKeys));
    writeIfMissing(configDir() + QStringLiteral("/hooks.conf"), starterHooks());
    setProperty("agtermConfigDir", configDir());
    reloadKeymap();
    reloadHooks();
}

int MainWindow::reloadKeymap()
{
    QString error;
    const QString path = configDir() + QStringLiteral("/keymap.conf");
    m_keymap = parseKeymap(readText(path, &error), m_defaultKeys);
    if (!error.isEmpty())
        m_keymap.diagnostics.prepend({0, QStringLiteral("could not read keymap.conf: %1").arg(error)});
    auto sequences = [](const QStringList &keys) {
        QList<QKeySequence> out;
        for (const QString &k : keys)
            out << QKeySequence(k, QKeySequence::PortableText);
        return out;
    };
    for (auto it = m_keymap.bindings.begin(); it != m_keymap.bindings.end(); ++it)
        if (QAction *a = m_actions.value(it.key()))
            a->setShortcuts(sequences(it.value()));
    qDeleteAll(m_customActions);
    m_customActions.clear();
    for (const CustomCommand &c : std::as_const(m_keymap.commands)) {
        auto *a = new QAction(c.name, this);
        a->setShortcuts(sequences(c.keys));
        a->setShortcutContext(Qt::ApplicationShortcut);
        a->setProperty("agtermCustom", true);
        connect(a, &QAction::triggered, this, [this, name = c.name] { runCustomCommand(name, m_store.selected); });
        addAction(a);
        m_customActions << a;
    }
    stripPartShortcuts();
    if (!m_keymap.diagnostics.isEmpty())
        statusBar()->showMessage(tr("keymap.conf: %n issue(s), see Settings > Key Mapping", nullptr, int(m_keymap.diagnostics.size())), 5000);
    return int(m_keymap.diagnostics.size());
}

int MainWindow::reloadHooks()
{
    return m_hooks->load(configDir() + QStringLiteral("/hooks.conf"));
}

void MainWindow::editConfigFile(const QString &path)
{
    // master opens $VISUAL/$EDITOR in a 95% overlay and reloads on quit; without overlays it runs in a companion
    QDir().mkpath(QFileInfo(path).path());
    writeIfMissing(path, path.endsWith(QLatin1String("keymap.conf")) ? starterKeymap(m_defaultKeys) : starterHooks());
    QString quoted = path;
    quoted.replace(QLatin1Char('\''), QStringLiteral("'\\''"));
    // resolved here: the pane's shell may be fish, which has no ${VAR:-default}
    const QString editor = qEnvironmentVariable("VISUAL", qEnvironmentVariable("EDITOR", QStringLiteral("vi")));
    const QString command = QStringLiteral("exec %1 '%2'").arg(editor, quoted);
    const QString id = m_store.session(m_store.selected) ? m_store.addCompanion(m_store.selected, QFileInfo(path).fileName(), QFileInfo(path).path(), command)
                                                         : m_store.addSession(currentWorkspace(), QFileInfo(path).fileName(), QFileInfo(path).path(), command);
    m_editing.insert(id, path);
    m_store.select(id);
}

QList<KParts::ReadOnlyPart *> MainWindow::parts() const
{
    QList<KParts::ReadOnlyPart *> out;
    for (const Panes &p : m_panes)
        for (KParts::ReadOnlyPart *part : {p.main, p.right})
            if (part)
                out << part;
    return out;
}

QObject *MainWindow::sessionOf(KParts::ReadOnlyPart *part) const
{
    auto *t = qobject_cast<TerminalInterface *>(part);
    const int pid = t ? t->terminalProcessId() : -1;
    for (int n = 1; pid > 0 && n < 4096; ++n) {
        QObject *o = QDBusConnection::sessionBus().objectRegisteredAt(QStringLiteral("/Sessions/%1").arg(n));
        int sessionPid = -1;
        if (o && QMetaObject::invokeMethod(o, "processId", Q_RETURN_ARG(int, sessionPid)) && sessionPid == pid)
            return o;
    }
    return nullptr;
}

QStringList MainWindow::themes() const
{
    // Konsole bundles its schemes as resources of the part's library; the user's live in the data dirs
    QStringList dirs{QStringLiteral(":/konsole/color-schemes")};
    dirs << QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("konsole"), QStandardPaths::LocateDirectory);
    QStringList names;
    for (const QString &d : std::as_const(dirs))
        for (QDirIterator it(d, {QStringLiteral("*.colorscheme")}, QDir::Files); it.hasNext();)
            names << it.nextFileInfo().completeBaseName();
    names.removeDuplicates();
    names.sort(Qt::CaseInsensitive);
    return names;
}

// what the default profile itself sets, so a cleared setting goes back to it
struct ProfileLook {
    QString scheme, cursorShape, blink;
};
static ProfileLook profileLook()
{
    ProfileLook look{QStringLiteral("Breeze"), QStringLiteral("0"), QStringLiteral("false")}; // Konsole's FALLBACK profile
    const QString name = KSharedConfig::openConfig()->group(QStringLiteral("Desktop Entry")).readEntry("DefaultProfile", QString());
    const QString file = name.isEmpty() ? QString() : QStandardPaths::locate(QStandardPaths::GenericDataLocation, QStringLiteral("konsole/") + name);
    if (!file.isEmpty()) {
        KConfig profile(file, KConfig::SimpleConfig);
        look.scheme = profile.group(QStringLiteral("Appearance")).readEntry("ColorScheme", look.scheme);
        look.cursorShape = profile.group(QStringLiteral("Cursor Options")).readEntry("CursorShape", look.cursorShape);
        look.blink = profile.group(QStringLiteral("Terminal Features")).readEntry("BlinkingCursorEnabled", look.blink);
    }
    return look;
}

void MainWindow::applyAppearance(KParts::ReadOnlyPart *part)
{
    const Settings &s = m_store.settings;
    const ProfileLook look = profileLook();
    static const QHash<QString, QString> shapes{{QStringLiteral("block"), QStringLiteral("0")}, {QStringLiteral("bar"), QStringLiteral("1")},
                                                {QStringLiteral("underline"), QStringLiteral("2")}};
    // the Session's own profile-change signal (what OSC 50 raises): a per-session override, no profile file written.
    // Part::changeSessionSettings would type the escape sequence into the shell instead.
    const QString command = QStringLiteral("ColorScheme=%1;CursorShape=%2;BlinkingCursorEnabled=%3")
                                .arg(!m_previewTheme.isEmpty() ? m_previewTheme : s.theme.isEmpty() ? look.scheme : s.theme,
                                     shapes.value(s.cursorStyle, look.cursorShape),
                                     s.cursorBlink.isEmpty() ? look.blink : s.cursorBlink == QLatin1String("blink") ? QStringLiteral("true") : QStringLiteral("false"));
    // nothing to override until a setting or a preview asks; after that a revert goes back to the profile's values
    const bool overrides = !m_previewTheme.isEmpty() || !s.theme.isEmpty() || !s.cursorStyle.isEmpty() || !s.cursorBlink.isEmpty();
    if (overrides || part->property("agtermLookOverridden").toBool())
        if (QObject *ks = sessionOf(part)) {
            QMetaObject::invokeMethod(ks, "profileChangeCommandReceived", Q_ARG(QString, command));
            part->setProperty("agtermLookOverridden", overrides);
        }

    // a Font= profile command does not reach the display; setFont does, and a Ctrl+wheel there and back relays the grid out
    QWidget *display = nullptr;
    for (QWidget *w : part->widget()->findChildren<QWidget *>())
        if (w->inherits("Konsole::TerminalDisplay"))
            display = w;
    if (!display)
        return;
    QFont font = display->property("agtermProfileFont").value<QFont>();
    if (!s.fontFamily.isEmpty())
        font.setFamily(s.fontFamily);
    if (s.fontSize > 0)
        font.setPointSizeF(s.fontSize);
    const double base = font.pointSizeF();
    if (display->property("agtermBaseFont").toDouble() == base && display->font().family() == font.family())
        return;
    const bool zoomed = qAbs(display->font().pointSizeF() - display->property("agtermBaseFont").toDouble()) >= 0.5;
    const double zoom = display->font().pointSizeF();
    if (zoomed)
        font.setPointSizeF(zoom); // an explicit zoom keeps its size, in the new family
    display->setFont(font);
    for (int delta : {120, -120}) {
        const QPointF at(4, 4);
        QWheelEvent wheel(at, display->mapToGlobal(at), {}, QPoint(0, delta), Qt::NoButton, Qt::ControlModifier, Qt::NoScrollPhase, false);
        QApplication::sendEvent(display, &wheel);
    }
    display->setProperty("agtermBaseFont", base);
}

void MainWindow::previewTheme(const QString &name)
{
    m_previewTheme = name;
    for (KParts::ReadOnlyPart *part : parts())
        applyAppearance(part);
}

void MainWindow::selectTheme()
{
    // View > Select Theme…: moving through the list previews on every open terminal; Enter commits, Esc reverts
    const QString committed = m_store.settings.theme;
    QList<Palette::Item> items;
    const QString fallback = profileLook().scheme;
    items.append({tr("Profile default"), tr("the scheme your Konsole profile sets (%1)").arg(fallback),
                  [this] {
                      previewTheme({});
                      Settings s = m_store.settings;
                      s.theme.clear();
                      m_store.setSettings(s);
                  },
                  true, [this, fallback] { previewTheme(fallback); }});
    int current = 0;
    for (const QString &t : themes()) {
        if (t == committed)
            current = int(items.size());
        items.append({t, t == committed ? tr("current") : QString(),
                      [this, t] {
                          previewTheme({});
                          Settings s = m_store.settings;
                          s.theme = t;
                          m_store.setSettings(s);
                      },
                      true, [this, t] { previewTheme(t); }});
    }
    m_palette->open(tr("Select a theme…"), items, false, [this] { previewTheme({}); }, current);
}

void MainWindow::customCommandPalette()
{
    QList<Palette::Item> items;
    for (const CustomCommand &c : std::as_const(m_keymap.commands))
        items.append({c.name, c.raw.isEmpty() ? c.command : c.raw + QStringLiteral("  ") + c.command,
                      [this, name = c.name] { runCustomCommand(name, m_store.selected); }});
    if (items.isEmpty())
        items.append({tr("No custom commands"), tr("define them in keymap.conf (File > Edit Keymap…)"), {}, false});
    m_palette->open(tr("Run a custom command…"), items);
}

void MainWindow::runCustomCommand(const QString &name, const QString &sessionId)
{
    const CustomCommand *c = nullptr;
    for (const CustomCommand &cc : std::as_const(m_keymap.commands))
        if (cc.name == name)
            c = &cc;
    if (!c)
        return;
    const Session *s = m_store.session(sessionId);
    QHash<QString, QString> ctx{{QStringLiteral("AGT_SOCKET"), socketPath()},
                                // shortcut: the PRIMARY selection stands for the pane's selection (Konsole mirrors it there)
                                {QStringLiteral("AGT_SELECTION"), QApplication::clipboard()->text(QClipboard::Selection)}};
    if (s) {
        const Panes p = m_panes.value(s->id);
        const bool right = p.right && p.right->widget()->isAncestorOf(QApplication::focusWidget());
        const QString live = liveCwd(s->id);
        ctx.insert(QStringLiteral("AGT_SESSION_ID"), s->id);
        ctx.insert(QStringLiteral("AGT_SESSION_NAME"), s->displayName());
        ctx.insert(QStringLiteral("AGT_SESSION_PWD"), live.isEmpty() ? s->cwd : live);
        ctx.insert(QStringLiteral("AGT_WORKSPACE_ID"), m_store.workspaceOf(s->id)->id);
        ctx.insert(QStringLiteral("AGT_WORKSPACE_NAME"), m_store.workspaceOf(s->id)->name);
        ctx.insert(QStringLiteral("AGT_PANE"), right ? QStringLiteral("right") : QStringLiteral("left"));
    }
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const QString &t : commandTokens())
        env.insert(t, ctx.value(t));
    env.insert(QStringLiteral("PATH"), QCoreApplication::applicationDirPath() + QLatin1Char(':') + env.value(QStringLiteral("PATH")));
    // parentless, so quitting the app neither kills a launched program nor waits for it
    auto *proc = new QProcess;
    proc->setProcessEnvironment(env);
    proc->setStandardInputFile(QProcess::nullDevice());
    proc->setStandardOutputFile(QProcess::nullDevice());
    if (!c->errorHud)
        proc->setStandardErrorFile(QProcess::nullDevice());
    if (QFileInfo(ctx.value(QStringLiteral("AGT_SESSION_PWD"))).isDir())
        proc->setWorkingDirectory(ctx.value(QStringLiteral("AGT_SESSION_PWD")));
    const bool hud = c->errorHud;
    connect(proc, &QProcess::finished, this, [this, proc, name, hud](int code, QProcess::ExitStatus status) {
        if (code != 0 || status == QProcess::CrashExit) {
            // no HUD here yet: --error-hud puts the command's stderr in the notification instead
            const QString err = hud ? QString::fromUtf8(proc->readAllStandardError()).trimmed().right(400) : QString();
            notifyFailure(tr("%1 failed").arg(name), (status == QProcess::CrashExit ? tr("killed by a signal") : tr("exit status %1").arg(code))
                                                         + (err.isEmpty() ? QString() : QStringLiteral("\n") + err));
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, name](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            notifyFailure(tr("%1 failed").arg(name), proc->errorString());
            proc->deleteLater();
        }
    });
    proc->start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), expandTokens(c->command, ctx)});
}

void MainWindow::notifyFailure(const QString &title, const QString &body)
{
    if (!m_store.settings.notificationsEnabled) {
        statusBar()->showMessage(title + QStringLiteral(": ") + body, 5000);
        return;
    }
    KNotification::event(KNotification::Error, title, body, QStringLiteral("agterm-qt"));
}

void MainWindow::playSound(const QString &name) const
{
    if (name.isEmpty())
        return;
    for (const char *theme : {"ocean", "freedesktop"})
        for (const char *ext : {".oga", ".ogg", ".wav"})
            if (const QString file = QStandardPaths::locate(QStandardPaths::GenericDataLocation,
                                                            QStringLiteral("sounds/%1/stereo/%2%3").arg(QLatin1String(theme), name, QLatin1String(ext)));
                !file.isEmpty()) {
                QProcess::startDetached(QStringLiteral("pw-play"), {file}) || QProcess::startDetached(QStringLiteral("paplay"), {file});
                return;
            }
}

// Konsole::Session::emulation() is exported but not a meta-method; the plugin loads libkonsoleprivate privately,
// so the symbol is found through the library that holds the Session's meta-object
static QObject *emulationOf(QObject *session)
{
    Dl_info info{};
    if (!session || !dladdr(session->metaObject(), &info) || !info.dli_fname)
        return nullptr;
    void *lib = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    void *sym = lib ? dlsym(lib, "_ZNK7Konsole7Session9emulationEv") : nullptr;
    if (lib)
        dlclose(lib); // NOLOAD only took a reference
    QObject *emulation = sym ? reinterpret_cast<QObject *(*)(const QObject *)>(sym)(session) : nullptr;
    return emulation && emulation->inherits("Konsole::Emulation") ? emulation : nullptr;
}

void MainWindow::watchTerminalNotifications(KParts::ReadOnlyPart *part, PartBridge *bridge)
{
    QObject *session = sessionOf(part);
    QObject *emulation = emulationOf(session);
    if (!emulation)
        return; // a Konsole without that symbol: no OSC notifications, everything else unaffected
    bridge->session = session;
    connect(emulation, SIGNAL(sessionAttributeChanged(int, QString)), bridge, SLOT(sessionAttribute(int, QString)));
    // OSC 777 notify comes to us, not to Konsole's own banner; the container forms are forwarded by the bridge.
    // Konsole connects handleOsc777 by member pointer, which only a receiver-wide disconnect reaches.
    disconnect(emulation, SIGNAL(osc777Received(QStringList)), session, nullptr);
    connect(emulation, SIGNAL(osc777Received(QStringList)), bridge, SLOT(osc777(QStringList)));
}

void PartBridge::sessionAttribute(int what, const QString &text)
{
    if (what == 9 && !text.isEmpty() && !text.startsWith(QLatin1String("4;"))) // 9;4 is ConEmu's progress report, not a message
        m_store.notify(m_id, {}, text);
}

void PartBridge::osc777(const QStringList &params)
{
    if (params.value(0) == QLatin1String("notify"))
        m_store.notify(m_id, params.value(1), params.mid(2).join(QLatin1Char(';')));
    else if (session)
        QMetaObject::invokeMethod(session, "handleOsc777", Q_ARG(QStringList, params));
}

void MainWindow::applySettings()
{
    const Settings &s = m_store.settings;
    for (auto it = m_chrome.begin(); it != m_chrome.end(); ++it)
        it.value()->setVisible(s.shows(it.key()));
    for (auto it = m_footer.begin(); it != m_footer.end(); ++it)
        it.value()->setVisible(s.shows(it.key()));
    QFont sideFont = QApplication::font();
    if (s.sidebarFontSize > 0)
        sideFont.setPointSizeF(s.sidebarFontSize);
    m_tree->setFont(sideFont);
    QFont paletteFont = QApplication::font();
    if (s.interfaceFontSize > 0)
        paletteFont.setPointSizeF(s.interfaceFontSize);
    m_palette->setFont(paletteFont);
    m_tree->viewport()->update();
    const QString look = QStringList{s.theme, s.fontFamily, QString::number(s.fontSize), s.cursorStyle, s.cursorBlink}.join(QLatin1Char('\n'));
    if (look != m_appliedAppearance) {
        m_appliedAppearance = look;
        for (KParts::ReadOnlyPart *part : parts())
            applyAppearance(part);
    }
    if (property("agtermConfigDir").isValid() && property("agtermConfigDir").toString() != configDir())
        loadConfig(); // a new config directory reloads both files
}

bool MainWindow::appCommand(const QString &cmd, const QString &sessionId, const QJsonObject &args, QJsonObject *result, QString *error)
{
    auto diagnostics = [](const QList<KeymapDiagnostic> &list) {
        QJsonArray out;
        for (const auto &d : list)
            out << QJsonObject{{"line", d.line}, {"message", d.message}};
        return out;
    };
    if (cmd == QLatin1String("keymap.reload") || cmd == QLatin1String("hooks.reload")) {
        *result = {{"count", cmd == QLatin1String("keymap.reload") ? reloadKeymap() : reloadHooks()}};
        return true;
    }
    if (cmd == QLatin1String("hooks.list")) {
        *result = {{"hooks", m_hooks->list()}};
        return true;
    }
    if (cmd == QLatin1String("keymap.list")) {
        auto spell = [](const QList<QKeySequence> &keys) {
            QStringList out;
            for (const auto &k : keys)
                out << k.toString(QKeySequence::PortableText);
            return out;
        };
        QJsonArray actions, commands, menu;
        for (auto it = m_keymap.bindings.begin(); it != m_keymap.bindings.end(); ++it) {
            const QStringList keys = spell(m_actions.value(it.key())->shortcuts());
            QJsonObject row{{"name", it.key()}, {"chord", keys.value(0)}};
            if (keys.size() > 1)
                row.insert("alternates", QJsonArray::fromStringList(keys.mid(1)));
            if (m_keymap.raw.contains(it.key()))
                row.insert("marked", true);
            actions << row;
        }
        for (const CustomCommand &c : std::as_const(m_keymap.commands)) {
            QJsonObject row{{"name", c.name}, {"shortcut", c.keys.join(QLatin1Char('|'))}, {"command", c.command}, {"repeats", false},
                            {"errorHud", c.errorHud}, {"errorPosition", c.errorPosition}};
            if (!c.errorPane.isEmpty())
                row.insert("errorPane", c.errorPane);
            commands << row;
        }
        for (QMenu *m : menuBar()->findChildren<QMenu *>())
            for (QAction *a : m->actions())
                if (!a->shortcut().isEmpty())
                    menu << QJsonObject{{"title", a->text().remove(QLatin1Char('&'))}, {"chord", a->shortcut().toString(QKeySequence::PortableText)},
                                        {"enabled", a->isEnabled()}};
        *result = {{"keymap", QJsonObject{{"path", configDir() + QStringLiteral("/keymap.conf")},
                                          {"actions", actions},
                                          {"commands", commands},
                                          {"diagnostics", diagnostics(m_keymap.diagnostics)},
                                          {"menu", menu}}}};
        return true;
    }
    if (cmd == QLatin1String("keymap.run")) {
        const QString name = args.value("name").toString();
        bool known = false;
        for (const CustomCommand &c : std::as_const(m_keymap.commands))
            known |= c.name == name;
        if (!known)
            return *error = QStringLiteral("no custom command named '%1'").arg(name), false;
        runCustomCommand(name, sessionId);
        *result = {{"id", sessionId}};
        return true;
    }
    if (cmd == QLatin1String("theme.list")) {
        *result = {{"themes", QJsonArray::fromStringList(themes())}};
        if (!m_store.settings.theme.isEmpty())
            result->insert("theme", m_store.settings.theme); // absent: the Konsole profile's own scheme
        return true;
    }
    if (cmd == QLatin1String("theme.set")) {
        const QString name = args.value("name").toString();
        if (!name.isEmpty() && !themes().contains(name))
            return *error = QStringLiteral("unknown theme: %1").arg(name), false;
        Settings s = m_store.settings;
        s.theme = name;
        m_store.setSettings(s);
        *result = name.isEmpty() ? QJsonObject{} : QJsonObject{{"theme", name}};
        return true;
    }
    *error = QStringLiteral("unknown command '%1'").arg(cmd);
    return false;
}
