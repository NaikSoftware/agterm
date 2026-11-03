#include "control.h"

#include "paths.h"
#include "store.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>

static QJsonObject ok(const QJsonObject &result = {})
{
    return {{"ok", true}, {"result", result}};
}

static QJsonObject fail(const QString &error)
{
    return {{"ok", false}, {"error", error}};
}

static QJsonObject sessionNode(const Session &s, const QString &selected)
{
    return {{"id", s.id},         {"name", s.displayName()}, {"customName", !s.name.isEmpty()}, {"cwd", s.cwd},
            {"status", s.status}, {"blink", s.blink},         {"flagged", s.flagged},            {"agent", s.agent},
            {"title", s.title},   {"active", s.id == selected}};
}

static QJsonObject tree(Store &store)
{
    QJsonArray ws;
    for (const auto &w : store.workspaces) {
        QJsonArray ss;
        bool active = false;
        for (const auto &s : w.sessions) {
            ss << sessionNode(s, store.selected);
            active |= s.id == store.selected;
        }
        ws << QJsonObject{{"id", w.id}, {"name", w.name}, {"rememberedFolder", w.folder}, {"active", active}, {"sessions", ss}};
    }
    return {{"workspaces", ws}};
}

static QJsonObject sessionNew(Store &store, const QJsonObject &args)
{
    QString cwd = args.value("cwd").toString();
    if (cwd.startsWith(QLatin1Char('~')))
        cwd = QDir::homePath() + cwd.mid(1);
    if (!cwd.isEmpty() && !QFileInfo(cwd).isDir())
        return fail(QStringLiteral("not a directory: %1").arg(cwd));
    if (!cwd.isEmpty())
        cwd = QFileInfo(cwd).absoluteFilePath();

    QString error, wsId;
    const QString wsName = args.value("workspaceName").toString();
    if (!wsName.isEmpty()) {
        for (const auto &w : store.workspaces)
            if (w.name == wsName)
                wsId = w.id;
        if (wsId.isEmpty() && !args.value("createWorkspace").toBool())
            return fail(QStringLiteral("no workspace named '%1' (pass --create-workspace)").arg(wsName));
        if (wsId.isEmpty())
            wsId = store.addWorkspace(wsName);
    } else if (store.workspaces.isEmpty() && args.value("workspace").toString().isEmpty()) {
        wsId = store.addWorkspace(QStringLiteral("main"));
    } else if (!cwd.isEmpty() && args.value("workspace").toString().isEmpty() && !store.workspaceRemembering(cwd).isEmpty()) {
        wsId = store.workspaceRemembering(cwd); // a bare --cwd joins the workspace that lives there
    } else if (wsId = store.resolveWorkspace(args.value("workspace").toString(), &error); wsId.isEmpty()) {
        return fail(error);
    }
    if (cwd.isEmpty()) {
        const Session *cur = store.session(store.selected);
        cwd = store.newSessionCwd(wsId, cur ? cur->cwd : QString());
    }

    const QString id = store.addSession(wsId, args.value("name").toString(), cwd, args.value("command").toString());
    if (!args.value("noSelect").toBool())
        store.select(id);
    return ok({{"id", id}});
}

QJsonObject dispatch(Store &store, Terminals &terminals, const QJsonObject &request)
{
    const QString cmd = request.value("cmd").toString();
    const QString target = request.value("target").toString();
    const QJsonObject args = request.value("args").toObject();
    QString error;

    if (cmd == QLatin1String("tree"))
        return ok({{"tree", tree(store)}});
    if (cmd == QLatin1String("version"))
        return ok({{"text", QStringLiteral("agterm-qt %1").arg(QLatin1String(appVersion))}});
    if (cmd == QLatin1String("workspace.new"))
        return ok({{"id", store.addWorkspace(args.value("name").toString())}});
    if (cmd == QLatin1String("session.new"))
        return sessionNew(store, args);
    if (cmd == QLatin1String("session.go")) {
        const QString id = store.go(args.value("to").toString(), &error);
        return id.isEmpty() ? fail(error) : ok({{"id", id}});
    }

    if (cmd.startsWith(QLatin1String("workspace."))) {
        const QString id = store.resolveWorkspace(target, &error);
        if (id.isEmpty())
            return fail(error);
        if (cmd == QLatin1String("workspace.rename")) {
            if (args.value("name").toString().isEmpty())
                return fail(QStringLiteral("name is required"));
            store.renameWorkspace(id, args.value("name").toString());
        } else if (cmd == QLatin1String("workspace.move")) {
            store.moveWorkspace(id, args.value("index").toInt());
        } else if (cmd == QLatin1String("workspace.delete")) {
            store.removeWorkspace(id);
        } else if (cmd == QLatin1String("workspace.select")) {
            const auto &ss = store.workspace(id)->sessions;
            if (ss.isEmpty())
                return fail(QStringLiteral("workspace has no sessions"));
            store.select(ss.first().id);
        } else {
            return fail(QStringLiteral("unknown command '%1'").arg(cmd));
        }
        return ok({{"id", id}});
    }

    if (cmd.startsWith(QLatin1String("session."))) {
        const QString id = store.resolveSession(target, &error);
        if (id.isEmpty())
            return fail(error);
        if (cmd == QLatin1String("session.close")) {
            store.removeSession(id);
        } else if (cmd == QLatin1String("session.select")) {
            store.select(id);
        } else if (cmd == QLatin1String("session.rename")) {
            store.renameSession(id, args.value("name").toString()); // empty reverts to the directory name
        } else if (cmd == QLatin1String("session.status")) {
            const QString status = args.value("status").toString();
            if (!store.setStatus(id, status, args.value("autoReset").toBool(), args.value("blink").toBool()))
                return fail(QStringLiteral("status must be one of %1").arg(Store::statuses.join(QLatin1String(", "))));
        } else if (cmd == QLatin1String("session.flag")) {
            const QString mode = args.value("mode").toString(QStringLiteral("toggle"));
            if (mode != QLatin1String("on") && mode != QLatin1String("off") && mode != QLatin1String("toggle"))
                return fail(QStringLiteral("mode must be on, off or toggle"));
            store.setFlag(id, mode == QLatin1String("toggle") ? !store.session(id)->flagged : mode == QLatin1String("on"));
        } else if (cmd == QLatin1String("session.move")) {
            const QString ws = store.resolveWorkspace(args.value("workspace").toString(), &error);
            if (ws.isEmpty())
                return fail(error);
            store.moveSession(id, ws, args.contains("index") ? args.value("index").toInt() : -1);
        } else if (cmd == QLatin1String("session.duplicate")) {
            const QString copy = store.duplicateSession(id, {});
            if (!args.value("noSelect").toBool())
                store.select(copy);
            return ok({{"id", copy}});
        } else if (cmd == QLatin1String("session.type")) {
            if (!terminals.type(id, args.value("text").toString(), &error))
                return fail(error);
        } else if (cmd == QLatin1String("session.text")) {
            QString text = terminals.text(id, &error);
            if (!error.isEmpty())
                return fail(error);
            if (const int lines = args.value("lines").toInt(); lines > 0) {
                auto all = text.split(QLatin1Char('\n'));
                while (!all.isEmpty() && all.last().isEmpty())
                    all.removeLast();
                text = all.mid(qMax(0, int(all.size()) - lines)).join(QLatin1Char('\n'));
            }
            return ok({{"id", id}, {"text", text}});
        } else if (cmd == QLatin1String("session.info")) {
            QJsonObject node = sessionNode(*store.session(id), store.selected);
            node.insert("workspace", store.workspaceOf(id)->id);
            const QJsonObject live = terminals.info(id);
            for (auto it = live.begin(); it != live.end(); ++it)
                node.insert(it.key(), it.value());
            return ok({{"id", id}, {"session", node}});
        } else {
            return fail(QStringLiteral("unknown command '%1'").arg(cmd));
        }
        return ok({{"id", id}});
    }

    return fail(QStringLiteral("unknown command '%1'").arg(cmd));
}
