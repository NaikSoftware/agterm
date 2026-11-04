#include "library.h"

#include "control.h"
#include "mainwindow.h"
#include "store.h"

#include <QApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QScreen>
#include <QUuid>

static QJsonObject ok(const QJsonObject &result = {})
{
    return {{"ok", true}, {"result", result}};
}

static QJsonObject fail(const QString &error)
{
    return {{"ok", false}, {"error", error}};
}

static bool wayland()
{
    return QGuiApplication::platformName().startsWith(QLatin1String("wayland"));
}

WindowLibrary::WindowLibrary(const QString &stateDir)
    : m_dir(stateDir)
{
}

WindowLibrary::~WindowLibrary()
{
    m_quitting = true;
    for (Entry &e : m_entries) {
        delete e.window; // before its store: the window reads it while tearing down
        delete e.store;
    }
}

QString WindowLibrary::path(const QString &id) const
{
    return m_dir + QStringLiteral("/windows/") + id + QStringLiteral(".json");
}

void WindowLibrary::load()
{
    QDir().mkpath(m_dir + QStringLiteral("/windows"));
    QFile index(m_dir + QStringLiteral("/windows.json"));
    const QJsonObject saved = index.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(index.readAll()).object() : QJsonObject();
    for (const auto &v : saved.value("windows").toArray()) {
        const QJsonObject o = v.toObject();
        if (!o.value("id").toString().isEmpty())
            m_entries.append({o.value("id").toString(), o.value("name").toString(), o.value("open").toBool()});
    }
    if (m_entries.isEmpty()) {
        // the single-window layout of earlier builds becomes window 1
        Entry e{QUuid::createUuid().toString(QUuid::Id128).left(12), QStringLiteral("window 1"), true};
        QFile::rename(m_dir + QStringLiteral("/workspaces.json"), path(e.id));
        m_entries.append(e);
    }
    bool any = false;
    for (Entry &e : m_entries)
        if (e.open)
            attach(e), any = true;
    if (!any)
        attach(m_entries.first());
    if (Entry *front = entry(saved.value("active").toString()); front && front->open)
        select(front->id); // the window that was in front at quit is in front again
    saveIndex();
}

void WindowLibrary::attach(Entry &e, bool minimized)
{
    QJsonObject state;
    if (QFile f(path(e.id)); f.open(QIODevice::ReadOnly))
        state = QJsonDocument::fromJson(f.readAll()).object();
    e.store = new Store;
    e.store->fromJson(state);
    for (const Entry &other : std::as_const(m_entries))
        if (other.store && other.store != e.store) { // settings are app-wide, the restore mode frozen per process
            e.store->settings = other.store->settings;
            e.store->restoreModeAtLaunch = other.store->restoreModeAtLaunch;
            break;
        }
    e.window = new MainWindow(*e.store, path(e.id));
    e.window->library = this;
    e.window->windowId = e.id;
    e.window->restore(state.value("window").toObject());
    e.window->loadConfig();
    e.window->save(); // the replayed commands are gone from disk now, so a crash cannot run them twice
    if (e.store->allSessions().isEmpty()) {
        const QString ws = e.store->workspaces.isEmpty() ? e.store->addWorkspace(QStringLiteral("main")) : e.store->workspaces.first().id;
        e.store->select(e.store->addSession(ws, {}, {}));
    }
    connect(e.store, &Store::settingsChanged, this, [this, store = e.store] { syncSettings(store); });
    e.window->installEventFilter(this);
    e.open = true;
    minimized ? e.window->showMinimized() : e.window->show();
    if (!m_active || !minimized)
        m_active = e.window;
    Q_EMIT changed();
}

void WindowLibrary::syncSettings(Store *from)
{
    const QJsonObject wanted = from->settings.toJson();
    for (Entry &e : m_entries)
        if (e.store && e.store != from && e.store->settings.toJson() != wanted)
            e.store->setSettings(from->settings);
}

bool WindowLibrary::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() == QEvent::WindowActivate)
        if (auto *w = qobject_cast<MainWindow *>(watched))
            m_active = w; // tracked here: offscreen there is no active window to ask
    return QObject::eventFilter(watched, event);
}

QList<MainWindow *> WindowLibrary::openWindows() const
{
    QList<MainWindow *> out;
    for (const Entry &e : m_entries)
        if (e.open && e.window)
            out << e.window;
    return out;
}

MainWindow *WindowLibrary::active() const
{
    const QList<MainWindow *> open = openWindows();
    return m_active && open.contains(m_active) ? m_active.data() : open.value(0);
}

WindowLibrary::Entry *WindowLibrary::entry(const QString &id)
{
    for (Entry &e : m_entries)
        if (e.id == id)
            return &e;
    return nullptr;
}

WindowLibrary::Entry *WindowLibrary::entryOf(const MainWindow *window)
{
    for (Entry &e : m_entries)
        if (e.window == window)
            return &e;
    return nullptr;
}

QString WindowLibrary::resolve(const QString &selector, QString *error)
{
    if (selector.isEmpty() || selector == QLatin1String("active")) {
        if (Entry *e = entryOf(active()))
            return e->id;
        return *error = QStringLiteral("no open window"), QString();
    }
    QStringList hits;
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.id == selector)
            return e.id;
        if (e.id.startsWith(selector))
            hits << e.id;
    }
    if (hits.size() == 1)
        return hits.first();
    *error = hits.isEmpty() ? QStringLiteral("no such window: %1").arg(selector)
                            : QStringLiteral("ambiguous window prefix '%1' → %2").arg(selector, hits.join(QStringLiteral(", ")));
    return {};
}

QString WindowLibrary::newWindow(const QString &name, bool minimized)
{
    m_entries.append({QUuid::createUuid().toString(QUuid::Id128).left(12),
                      name.isEmpty() ? QStringLiteral("window %1").arg(m_entries.size() + 1) : name, false});
    attach(m_entries.last(), minimized);
    saveIndex();
    return m_entries.last().id;
}

bool WindowLibrary::select(const QString &id)
{
    Entry *e = entry(id);
    if (!e)
        return false;
    if (!e->open)
        attach(*e);
    e->window->setWindowState(e->window->windowState() & ~Qt::WindowMinimized);
    e->window->show();
    e->window->raise();
    e->window->activateWindow();
    m_active = e->window;
    saveIndex();
    return true;
}

void WindowLibrary::close(const QString &id)
{
    if (Entry *e = entry(id); e && e->open && e->window) {
        m_closing = id;
        e->window->close(); // not spontaneous: no confirmation; windowClosed does the rest
        m_closing.clear();
    }
}

void WindowLibrary::windowClosed(MainWindow *window, bool byUser)
{
    Entry *e = entryOf(window);
    if (!e || m_quitting || openWindows().size() < 2 || !(byUser || e->id == m_closing))
        return; // quitting, or the last window: it reopens next launch
    e->open = false;
    Store *store = std::exchange(e->store, nullptr);
    std::exchange(e->window, nullptr)->deleteLater();
    connect(window, &QObject::destroyed, store, &QObject::deleteLater);
    if (m_active == window)
        m_active = openWindows().value(0);
    saveIndex();
    Q_EMIT changed();
}

bool WindowLibrary::remove(const QString &id, QString *error)
{
    if (m_entries.size() < 2)
        return *error = QStringLiteral("cannot delete last window"), false;
    Entry *e = entry(id);
    if (!e)
        return *error = QStringLiteral("no such window: %1").arg(id), false;
    if (e->open && openWindows().size() == 1) // keep the app alive on another bundle
        for (const Entry &other : std::as_const(m_entries))
            if (other.id != id) {
                select(other.id);
                break;
            }
    close(id);
    QFile::remove(path(id));
    m_entries.removeIf([&id](const Entry &x) { return x.id == id; });
    saveIndex();
    Q_EMIT changed();
    return true;
}

void WindowLibrary::rename(const QString &id, const QString &name)
{
    if (Entry *e = entry(id)) {
        e->name = name;
        saveIndex();
        Q_EMIT changed();
    }
}

bool WindowLibrary::go(int step, QString *error)
{
    const QList<MainWindow *> open = openWindows();
    if (open.size() < 2)
        return *error = QStringLiteral("no other open window to navigate to"), false;
    const qsizetype at = qMax<qsizetype>(0, open.indexOf(active()));
    return select(entryOf(open[(at + step + open.size()) % open.size()])->id);
}

void WindowLibrary::quit()
{
    m_quitting = true; // every open window stays open in the index and reopens next launch
    for (MainWindow *w : openWindows())
        w->close();
    saveIndex();
    QApplication::quit();
}

bool WindowLibrary::saveIndex()
{
    QJsonArray list;
    for (const Entry &e : std::as_const(m_entries))
        list << QJsonObject{{"id", e.id}, {"name", e.name}, {"open", e.open}};
    QSaveFile f(m_dir + QStringLiteral("/windows.json"));
    if (!f.open(QIODevice::WriteOnly))
        return false;
    const Entry *front = entryOf(active());
    f.write(QJsonDocument(QJsonObject{{"version", 1}, {"windows", list}, {"active", front ? front->id : QString()}}).toJson());
    return f.commit();
}

QJsonObject WindowLibrary::dispatch(const QJsonObject &request)
{
    const QString cmd = request.value("cmd").toString(), target = request.value("target").toString();
    const QJsonObject args = request.value("args").toObject();
    if (cmd.startsWith(QLatin1String("window.")))
        return windowCommand(cmd, target, args);
    const QList<MainWindow *> open = openWindows();
    if (open.isEmpty())
        return fail(QStringLiteral("no open window"));
    // config the whole app shares, and the app-global restore commands, act on every open window
    static const QStringList everywhere{"keymap.reload", "hooks.reload", "theme.set", "restore.capture", "restore.clear"};
    if (everywhere.contains(cmd)) {
        QJsonObject last;
        int count = 0;
        for (const Entry &e : std::as_const(m_entries))
            if (e.open && e.window) {
                last = ::dispatch(*e.store, *e.window, request);
                if (!last.value("ok").toBool())
                    return last;
                count += last.value("result").toObject().value("count").toInt();
            }
        if (cmd == QLatin1String("restore.capture"))
            return ok({{"count", count}, {"text", QStringLiteral("captured %1 command(s)").arg(count)}});
        return last;
    }
    Entry *e = entryOf(active());
    QString error;
    if (args.contains("window")) {
        const QString id = resolve(args.value("window").toString(), &error);
        if (id.isEmpty())
            return fail(error);
        if (!(e = entry(id))->open)
            return fail(QStringLiteral("window not open — window.select it first"));
    } else if (!target.isEmpty() && cmd != QLatin1String("session.new")) {
        // a session or workspace id is found in whichever open window holds it, the frontmost first
        const bool workspace = cmd.startsWith(QLatin1String("workspace."));
        QList<Entry *> order{e};
        for (Entry &x : m_entries)
            if (x.open && x.window && &x != e)
                order << &x;
        for (Entry *x : order) {
            QString ignored;
            if (!(workspace ? x->store->resolveWorkspace(target, &ignored) : x->store->resolveSession(target, &ignored)).isEmpty()) {
                e = x;
                break;
            }
        }
    }
    return ::dispatch(*e->store, *e->window, request);
}

QJsonObject WindowLibrary::windowCommand(const QString &cmd, const QString &target, const QJsonObject &args)
{
    QString error;
    if (cmd == QLatin1String("window.list")) {
        QJsonArray list;
        for (const Entry &e : std::as_const(m_entries)) {
            QJsonObject o{{"id", e.id}, {"name", e.name}, {"open", e.open}, {"active", e.window && e.window == active()}};
            if (e.open && e.window) {
                QWidget *w = e.window;
                QJsonObject geometry{{"width", w->width()}, {"height", w->height()}, {"display", QGuiApplication::screens().indexOf(w->screen())}};
                if (!wayland()) { // Wayland never tells a client where its window is
                    const QPoint at = w->frameGeometry().topLeft() - w->screen()->geometry().topLeft();
                    geometry.insert("x", at.x());
                    geometry.insert("y", at.y());
                }
                o.insert("geometry", geometry);
                o.insert("sidebarVisible", e.window->chromeState().value("sidebarVisible"));
                o.insert("fullscreen", w->isFullScreen());
                o.insert("zoomed", w->isMaximized());
                o.insert("minimized", w->isMinimized());
            }
            list << o;
        }
        return ok({{"windows", list}});
    }
    if (cmd == QLatin1String("window.new"))
        return ok({{"id", newWindow(args.value("name").toString(), args.value("minimized").toBool())}});
    if (cmd == QLatin1String("window.go")) {
        const QString to = args.value("to").toString();
        if (to != QLatin1String("next") && to != QLatin1String("prev"))
            return fail(QStringLiteral("window.go requires --to next|prev"));
        if (!go(to == QLatin1String("next") ? 1 : -1, &error))
            return fail(error);
        return ok({{"id", entryOf(active())->id}});
    }
    const QString id = resolve(target, &error);
    if (id.isEmpty())
        return fail(error);
    Entry *e = entry(id);
    if (cmd == QLatin1String("window.select")) {
        select(id);
    } else if (cmd == QLatin1String("window.close")) {
        close(id);
    } else if (cmd == QLatin1String("window.rename")) {
        if (args.value("name").toString().isEmpty())
            return fail(QStringLiteral("window.rename requires a name"));
        rename(id, args.value("name").toString());
    } else if (cmd == QLatin1String("window.delete")) {
        if (!remove(id, &error))
            return fail(error);
    } else if (QStringList{"window.resize", "window.move", "window.zoom", "window.fullscreen", "window.minimize"}.contains(cmd)) {
        if (!e->open || !e->window)
            return fail(QStringLiteral("window not open — window.select it first"));
        QWidget *w = e->window;
        if (cmd == QLatin1String("window.resize")) {
            const int width = args.value("width").toInt(), height = args.value("height").toInt();
            if (width <= 0 || height <= 0)
                return fail(QStringLiteral("window.resize requires positive width and height"));
            const QRect avail = w->screen()->availableGeometry();
            w->resize(qBound(w->minimumSizeHint().width(), width, avail.width()), qBound(w->minimumSizeHint().height(), height, avail.height()));
            return ok({{"id", id}, {"width", w->width()}, {"height", w->height()}});
        }
        if (cmd == QLatin1String("window.move")) {
            if (!args.contains("x") || !args.contains("y"))
                return fail(QStringLiteral("window.move requires x and y"));
            if (wayland())
                return fail(QStringLiteral("window.move: Wayland does not let an application position its windows"));
            const QList<QScreen *> screens = QGuiApplication::screens();
            const int display = args.value("display").toInt(screens.indexOf(w->screen()));
            if (display < 0 || display >= screens.size())
                return fail(QStringLiteral("display %1 out of range (have %2)").arg(display).arg(screens.size()));
            const QRect area = screens[display]->availableGeometry();
            // a grabbable strip stays on screen
            const QPoint at(qBound(area.left() - w->width() + 80, area.left() + args.value("x").toInt(), area.right() - 80),
                            qBound(area.top(), area.top() + args.value("y").toInt(), area.bottom() - 40));
            w->move(at);
        } else if (cmd == QLatin1String("window.zoom")) {
            w->isMaximized() ? w->showNormal() : w->showMaximized();
        } else if (cmd == QLatin1String("window.fullscreen")) {
            w->setWindowState(w->windowState() ^ Qt::WindowFullScreen);
        } else {
            const QString mode = args.value("mode").toString(QStringLiteral("toggle"));
            if (!QStringList{"on", "off", "toggle"}.contains(mode))
                return fail(QStringLiteral("invalid window minimize mode: %1").arg(mode));
            const bool on = mode == QLatin1String("toggle") ? !w->isMinimized() : mode == QLatin1String("on");
            if (on && w->isFullScreen())
                return fail(QStringLiteral("cannot minimize a full-screen window — window.fullscreen it first"));
            w->setWindowState(on ? w->windowState() | Qt::WindowMinimized : w->windowState() & ~Qt::WindowMinimized);
        }
    } else {
        return fail(QStringLiteral("unknown command '%1'").arg(cmd));
    }
    return ok({{"id", id}});
}
