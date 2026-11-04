#include "hooks.h"

#include "store.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QSet>
#include <QUuid>

// one sequence and ring for the whole app, so events.read sees every window
static quint64 s_seq = 0;
static QList<QJsonObject> s_ring;
static const QString s_run = QUuid::createUuid().toString(QUuid::WithoutBraces);

EventSource::EventSource(Store &store, QObject *parent)
    : QObject(parent), m_store(store)
{
    m_treeTimer.setSingleShot(true);
    m_treeTimer.setInterval(100);
    connect(&m_treeTimer, &QTimer::timeout, this, [this] { emitEvent(QStringLiteral("tree.changed")); });
    snapshot();
    connect(&store, &Store::changed, this, [this] {
        // a split shown or hidden by any path fires once per real transition
        for (const Session *s : m_store.allSessions()) {
            const bool shown = s->hasSplit && s->splitVisible;
            if (m_splitShown.contains(s->id) && m_splitShown.value(s->id) != shown)
                emitEvent(QStringLiteral("pane.split"), m_store.workspaceOf(s->id)->id, s->id,
                          {{"name", s->displayName()}, {"status", shown ? "shown" : "hidden"}});
        }
        snapshot();
        m_treeTimer.start();
    });
    connect(&store, &Store::sessionAdded, this, [this](const QString &id) {
        const Session *s = m_store.session(id);
        QJsonObject payload{{"name", s->displayName()}};
        if (!s->parentId.isEmpty())
            payload.insert("parent", s->parentId);
        emitEvent(QStringLiteral("session.created"), m_store.workspaceOf(id)->id, id, payload);
        snapshot();
    });
    connect(&store, &Store::sessionRemoved, this, [this](const QString &id) {
        emitEvent(QStringLiteral("session.closed"), m_workspaceOf.value(id), id, {{"name", m_names.value(id)}});
    });
    connect(&store, &Store::selectionChanged, this, [this](const QString &id) {
        if (id == m_selected)
            return;
        const Session *s = m_store.session(id);
        QJsonObject payload;
        if (s)
            payload.insert("name", s->displayName());
        if (!m_selected.isEmpty())
            payload.insert("previous", m_selected);
        m_selected = id;
        emitEvent(QStringLiteral("session.selected"), s ? m_store.workspaceOf(id)->id : QString(), s ? id : QString(), payload);
    });
    connect(&store, &Store::statusChanged, this, [this](const QString &id, const QString &status) {
        const Session *s = m_store.session(id);
        if (!s)
            return;
        emitEvent(QStringLiteral("status"), m_store.workspaceOf(id)->id, id,
                  {{"name", s->displayName()}, {"status", status}, {"blink", s->blink}, {"previous", m_status.value(id, QStringLiteral("idle"))}});
        m_status.insert(id, status);
    });
    connect(&store, &Store::notified, this, [this](const QString &id, const QString &title, const QString &body) {
        const Session *s = m_store.session(id);
        if (s)
            emitEvent(QStringLiteral("notify"), m_store.workspaceOf(id)->id, id,
                      {{"name", s->displayName()}, {"title", title.isEmpty() ? s->displayName() : title}, {"body", body}});
    });
}

void EventSource::snapshot()
{
    for (const Workspace &w : std::as_const(m_store.workspaces))
        for (const Session &s : w.sessions) {
            m_workspaceOf.insert(s.id, w.id);
            m_names.insert(s.id, s.displayName());
            m_status.insert(s.id, s.status);
            m_splitShown.insert(s.id, s.hasSplit && s.splitVisible);
        }
    m_selected = m_store.selected;
}

void EventSource::emitEvent(const QString &kind, const QString &workspace, const QString &session, const QJsonObject &payload)
{
    QJsonObject e{{"seq", qint64(++s_seq)}, {"ts", QDateTime::currentMSecsSinceEpoch() / 1000.0}, {"kind", kind}, {"payload", payload}};
    if (!window.isEmpty())
        e.insert("window", window);
    if (!workspace.isEmpty())
        e.insert("workspace", workspace);
    if (!session.isEmpty())
        e.insert("session", session);
    s_ring.append(e);
    if (s_ring.size() > 4096)
        s_ring.removeFirst();
    Q_EMIT event(e);
}

const QStringList EventSource::kinds{"status", "notify", "session.created", "session.closed", "session.selected", "tree.changed", "pane.split",
                                     "pane.scratch", "pane.focused", "remote.opened", "remote.closed", "app.launched", "message"};

QJsonObject EventSource::read(const QJsonObject &args, QString *error)
{
    const bool hasRun = args.contains("run"), hasAfter = args.contains("after");
    const QJsonObject anchor{{"run", s_run}, {"next", qint64(s_seq)}, {"items", QJsonArray()}};
    if (hasRun != hasAfter)
        return *error = QStringLiteral("events.read requires --run and --after together"), anchor;
    bool numeric = true;
    const quint64 after = args.value("after").toString().toULongLong(&numeric);
    if (hasRun && QUuid::fromString(args.value("run").toString()).isNull())
        return *error = QStringLiteral("invalid event run id"), anchor;
    if (hasAfter && !numeric)
        return *error = QStringLiteral("invalid event cursor"), anchor;
    const int limit = args.contains("limit") ? args.value("limit").toInt() : 100;
    if (limit < 1 || limit > 1000)
        return *error = QStringLiteral("event limit must be between 1 and 1000"), anchor;
    QSet<QString> wanted;
    for (const auto &v : args.value("kinds").toArray())
        for (const QString &k : v.toString().split(QLatin1Char(','), Qt::SkipEmptyParts)) {
            if (!kinds.contains(k.trimmed()))
                return *error = QStringLiteral("invalid event kind: %1").arg(k.trimmed()), anchor;
            wanted << k.trimmed();
        }
    if (!hasRun)
        return anchor; // subscribe from now: no history is replayed
    if (args.value("run").toString() != s_run)
        return *error = QStringLiteral("event run changed"), anchor;
    if (after > s_seq)
        return *error = QStringLiteral("event cursor is ahead of the current sequence"), anchor;
    if (!s_ring.isEmpty() && after + 1 < quint64(s_ring.first().value("seq").toInteger()))
        return *error = QStringLiteral("event cursor expired"), anchor;
    QJsonArray items;
    quint64 next = s_seq;
    for (const QJsonObject &e : std::as_const(s_ring)) {
        const quint64 seq = e.value("seq").toInteger();
        if (seq <= after || (!wanted.isEmpty() && !wanted.contains(e.value("kind").toString())))
            continue;
        items << e;
        if (items.size() == limit) {
            next = seq;
            break;
        }
    }
    return {{"run", s_run}, {"next", qint64(next)}, {"items", items}};
}

HookRunner::HookRunner(QObject *parent)
    : QObject(parent)
{
}

HookRunner::~HookRunner()
{
    for (Hook *h : std::as_const(m_hooks)) {
        if (h->proc) {
            h->proc->disconnect(this);
            h->proc->kill();
            h->proc->waitForFinished(1000);
        }
        delete h;
    }
}

int HookRunner::load(const QString &file)
{
    path = file;
    diagnostics.clear();
    QString text;
    if (QFile f(file); f.open(QIODevice::ReadOnly))
        text = QString::fromUtf8(f.readAll());
    else if (QFile::exists(file))
        diagnostics.append({0, QStringLiteral("could not read hooks.conf: %1").arg(f.errorString())});
    const QList<HookLine> lines = parseHooks(text, &diagnostics);
    QList<Hook *> live, old = m_hooks;
    for (const HookLine &l : lines) {
        Hook *keep = nullptr;
        for (Hook *h : std::as_const(old))
            if (!h->retired && h->line.kind == l.kind && h->line.command == l.command) {
                keep = h;
                break;
            }
        if (keep) {
            old.removeOne(keep);
            keep->line.line = l.line;
            keep->reported = false; // a reload re-arms the failure banner
        } else {
            keep = new Hook;
            keep->line = l;
        }
        live << keep;
    }
    for (Hook *h : std::as_const(old)) {
        h->queue.clear();
        if (h->proc) {
            h->retired = true; // finishes its running script, accepts nothing more
            live << h;
        } else {
            delete h;
        }
    }
    m_hooks = live;
    return int(diagnostics.size());
}

void HookRunner::fire(const QJsonObject &event)
{
    const QString kind = event.value("kind").toString();
    for (Hook *h : std::as_const(m_hooks)) {
        if (h->retired || h->line.kind != kind)
            continue;
        h->queue.append(event);
        if (h->queue.size() > 256) {
            h->queue.removeFirst();
            ++h->dropped;
        }
        if (!h->proc)
            start(h);
    }
}

void HookRunner::start(Hook *h)
{
    if (h->queue.isEmpty())
        return;
    const QJsonObject e = h->queue.takeFirst();
    auto *p = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    const QJsonObject payload = e.value("payload").toObject();
    env.insert(QStringLiteral("AGT_EVENT_KIND"), e.value("kind").toString());
    env.insert(QStringLiteral("AGT_EVENT_STATUS"), payload.value("status").toString());
    env.insert(QStringLiteral("AGT_EVENT_HOST"), payload.value("host").toString());
    env.insert(QStringLiteral("AGT_SESSION_ID"), e.value("session").toString());
    env.insert(QStringLiteral("AGT_WORKSPACE_ID"), e.value("workspace").toString());
    env.insert(QStringLiteral("AGT_WINDOW_ID"), QString());
    env.insert(QStringLiteral("AGT_SOCKET"), socket);
    if (!pathPrefix.isEmpty())
        env.insert(QStringLiteral("PATH"), pathPrefix + QLatin1Char(':') + env.value(QStringLiteral("PATH")));
    p->setProcessEnvironment(env);
    h->proc = p;
    h->started = QDateTime::currentDateTime();
    connect(p, &QProcess::finished, this, [this, h](int code, QProcess::ExitStatus status) {
        finished(h, status == QProcess::CrashExit ? QStringLiteral("killed by a signal")
                    : code != 0                   ? QStringLiteral("exit status %1").arg(code)
                                                  : QString());
    });
    connect(p, &QProcess::errorOccurred, this, [this, h, p](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart)
            finished(h, QStringLiteral("could not start: %1").arg(p->errorString()));
    });
    p->start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"), h->line.command});
    p->write(QJsonDocument(e).toJson(QJsonDocument::Compact) + '\n');
    p->closeWriteChannel();
}

void HookRunner::finished(Hook *h, const QString &failure)
{
    if (!h->proc)
        return;
    h->proc->deleteLater();
    h->proc = nullptr;
    if (failure.isEmpty()) {
        h->lastFailure.clear();
        h->reported = false;
    } else {
        h->lastFailure = failure;
        if (!h->reported && !h->retired)
            Q_EMIT failed(QStringLiteral("on %1 %2").arg(h->line.kind, h->line.command), failure);
        h->reported = true;
    }
    if (h->retired) {
        m_hooks.removeOne(h);
        delete h;
        return;
    }
    start(h);
}

QJsonObject HookRunner::list() const
{
    QJsonArray diags, hooks;
    for (const auto &d : diagnostics)
        diags << QJsonObject{{"line", d.line}, {"message", d.message}};
    for (const Hook *h : m_hooks) {
        QJsonObject row{{"kind", h->line.kind}, {"command", h->line.command}, {"line", h->line.line},
                        {"pending", int(h->queue.size())}, {"dropped", qint64(h->dropped)}};
        if (h->proc) {
            row.insert("runningPid", qint64(h->proc->processId()));
            row.insert("elapsedSeconds", h->started.msecsTo(QDateTime::currentDateTime()) / 1000.0);
        }
        if (!h->lastFailure.isEmpty())
            row.insert("lastFailure", h->lastFailure);
        if (h->retired)
            row.insert("retired", true);
        hooks << row;
    }
    return {{"path", path}, {"diagnostics", diags}, {"hooks", hooks}};
}
