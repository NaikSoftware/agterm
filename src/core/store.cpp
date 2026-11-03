#include "store.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QUuid>

const QStringList Store::statuses = {QStringLiteral("idle"), QStringLiteral("active"), QStringLiteral("completed"),
                                     QStringLiteral("blocked")};

QString Store::newId()
{
    return QUuid::createUuid().toString(QUuid::Id128).left(12);
}

Session *Store::session(const QString &id)
{
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            if (s.id == id)
                return &s;
    return nullptr;
}

Workspace *Store::workspace(const QString &id)
{
    for (auto &w : workspaces)
        if (w.id == id)
            return &w;
    return nullptr;
}

Workspace *Store::workspaceOf(const QString &sessionId)
{
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            if (s.id == sessionId)
                return &w;
    return nullptr;
}

QList<Session *> Store::allSessions()
{
    QList<Session *> out;
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            out << &s;
    return out;
}

template<typename T>
static QString resolve(const QList<T *> &items, const QString &target, const char *kind, QString *error)
{
    QList<T *> prefix, named;
    for (T *i : items) {
        if (i->id == target)
            return i->id;
        if (target.size() >= 3 && i->id.startsWith(target))
            prefix << i;
        if (i->name == target)
            named << i;
    }
    const auto &hits = prefix.isEmpty() ? named : prefix;
    if (hits.size() == 1)
        return hits.first()->id;
    *error = hits.isEmpty() ? QStringLiteral("no %1 matches '%2'").arg(QLatin1String(kind), target)
                            : QStringLiteral("'%1' matches %2 %3s").arg(target).arg(hits.size()).arg(QLatin1String(kind));
    return {};
}

QString Store::resolveSession(const QString &target, QString *error)
{
    if (target.isEmpty() || target == QLatin1String("active")) {
        if (selected.isEmpty())
            *error = QStringLiteral("no active session");
        return selected;
    }
    return resolve(allSessions(), target, "session", error);
}

QString Store::resolveWorkspace(const QString &target, QString *error)
{
    if (target.isEmpty() || target == QLatin1String("active")) {
        if (auto *w = workspaceOf(selected))
            return w->id;
        if (!workspaces.isEmpty())
            return workspaces.first().id;
        *error = QStringLiteral("no workspaces");
        return {};
    }
    QList<Workspace *> ws;
    for (auto &w : workspaces)
        ws << &w;
    return resolve(ws, target, "workspace", error);
}

QString Store::addWorkspace(const QString &name)
{
    Workspace w{newId(), name.isEmpty() ? QStringLiteral("workspace %1").arg(workspaces.size() + 1) : name, {}};
    workspaces << w;
    Q_EMIT changed();
    return w.id;
}

QString Store::addSession(const QString &workspaceId, const QString &name, const QString &cwd, const QString &command)
{
    auto *w = workspace(workspaceId);
    if (!w)
        return {};
    Session s;
    s.id = newId();
    s.cwd = cwd.isEmpty() ? QDir::homePath() : cwd;
    s.name = !name.isEmpty() ? name : s.cwd == QDir::homePath() ? QStringLiteral("~") : QFileInfo(s.cwd).fileName();
    s.command = command;
    w->sessions << s;
    Q_EMIT sessionAdded(s.id);
    Q_EMIT changed();
    return s.id;
}

void Store::removeSession(const QString &id)
{
    auto *w = workspaceOf(id);
    if (!w)
        return;
    int i = 0;
    while (w->sessions[i].id != id)
        ++i;
    w->sessions.removeAt(i);
    if (selected == id) {
        // the neighbour in the same workspace, else whatever is left anywhere
        QString next;
        if (!w->sessions.isEmpty())
            next = w->sessions[qMin(i, int(w->sessions.size()) - 1)].id;
        else if (auto all = allSessions(); !all.isEmpty())
            next = all.first()->id;
        selected.clear();
        if (!next.isEmpty())
            select(next);
        else
            Q_EMIT selectionChanged({});
    }
    Q_EMIT sessionRemoved(id);
    Q_EMIT changed();
}

void Store::removeWorkspace(const QString &id)
{
    auto *w = workspace(id);
    if (!w)
        return;
    QStringList ids;
    for (const auto &s : w->sessions)
        ids << s.id;
    for (const auto &sid : ids)
        removeSession(sid);
    for (int i = 0; i < workspaces.size(); ++i)
        if (workspaces[i].id == id)
            workspaces.removeAt(i);
    Q_EMIT changed();
}

void Store::renameSession(const QString &id, const QString &name)
{
    if (auto *s = session(id); s && !name.isEmpty()) {
        s->name = name;
        Q_EMIT changed();
    }
}

void Store::renameWorkspace(const QString &id, const QString &name)
{
    if (auto *w = workspace(id); w && !name.isEmpty()) {
        w->name = name;
        Q_EMIT changed();
    }
}

void Store::select(const QString &id)
{
    auto *s = session(id);
    if (!s || selected == id)
        return;
    selected = id;
    if (s->status == QLatin1String("completed") && s->autoReset)
        setStatus(id, QStringLiteral("idle"));
    Q_EMIT selectionChanged(id);
    Q_EMIT changed();
}

bool Store::setStatus(const QString &id, const QString &status, bool autoReset)
{
    auto *s = session(id);
    if (!s || !statuses.contains(status))
        return false;
    s->autoReset = autoReset;
    if (s->status == status)
        return true;
    s->status = status;
    Q_EMIT statusChanged(id, status);
    Q_EMIT changed();
    return true;
}

void Store::setCwd(const QString &id, const QString &cwd)
{
    if (auto *s = session(id); s && !cwd.isEmpty() && s->cwd != cwd) {
        s->cwd = cwd;
        Q_EMIT changed();
    }
}

void Store::setTitle(const QString &id, const QString &title)
{
    if (auto *s = session(id); s && s->title != title) {
        s->title = title;
        Q_EMIT changed();
    }
}

void Store::keyPressed(const QString &id)
{
    if (auto *s = session(id); s && (s->status == QLatin1String("blocked") || s->status == QLatin1String("completed")))
        setStatus(id, QStringLiteral("idle"));
}

QString Store::go(const QString &direction, QString *error)
{
    const bool attention = direction.endsWith(QLatin1String("-attention"));
    const bool back = direction.startsWith(QLatin1String("prev"));
    if (!QStringList{"next", "prev", "next-attention", "prev-attention"}.contains(direction)) {
        *error = QStringLiteral("unknown direction '%1'").arg(direction);
        return {};
    }
    const auto all = allSessions();
    int at = -1;
    for (int i = 0; i < all.size(); ++i)
        if (all[i]->id == selected)
            at = i;
    const int n = all.size();
    for (int step = 1; step <= n; ++step) {
        const int idx = at < 0 ? (back ? n - step : step - 1) : ((at + (back ? -step : step)) % n + n) % n;
        auto *s = all[idx];
        if (!attention || s->status == QLatin1String("blocked") || s->status == QLatin1String("completed")) {
            select(s->id);
            return s->id;
        }
    }
    *error = all.isEmpty() ? QStringLiteral("no sessions") : QStringLiteral("no session needs attention");
    return {};
}

QJsonObject Store::toJson() const
{
    QJsonArray ws;
    for (const auto &w : workspaces) {
        QJsonArray ss;
        for (const auto &s : w.sessions)
            ss << QJsonObject{{"id", s.id}, {"name", s.name}, {"cwd", s.cwd}};
        ws << QJsonObject{{"id", w.id}, {"name", w.name}, {"sessions", ss}};
    }
    return {{"version", 1}, {"selected", selected}, {"workspaces", ws}};
}

void Store::fromJson(const QJsonObject &o)
{
    workspaces.clear();
    for (const auto &wv : o.value("workspaces").toArray()) {
        const auto wo = wv.toObject();
        Workspace w{wo.value("id").toString(), wo.value("name").toString(), {}};
        if (w.id.isEmpty())
            continue;
        for (const auto &sv : wo.value("sessions").toArray()) {
            const auto so = sv.toObject();
            Session s;
            s.id = so.value("id").toString();
            s.name = so.value("name").toString();
            s.cwd = so.value("cwd").toString();
            if (!s.id.isEmpty())
                w.sessions << s;
        }
        workspaces << w;
    }
    selected = session(o.value("selected").toString()) ? o.value("selected").toString() : QString();
    if (selected.isEmpty())
        if (auto all = allSessions(); !all.isEmpty())
            selected = all.first()->id;
}
