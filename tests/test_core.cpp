#include "control.h"
#include "store.h"

#include <QDir>
#include <QJsonArray>
#include <QSignalSpy>
#include <QTest>

class FakeTerminals : public Terminals
{
public:
    QString typed;
    QString screen = QStringLiteral("a\nb\nc\n\n");
    bool type(const QString &, const QString &text, QString *) override { return typed += text, true; }
    QString text(const QString &, QString *) override { return screen; }
    QJsonObject info(const QString &) override { return {{"pid", 42}}; }
};

class TestCore : public QObject
{
    Q_OBJECT

    const QJsonObject call(Store &s, FakeTerminals &t, const QString &cmd, const QString &target = {}, const QJsonObject &args = {})
    {
        return dispatch(s, t, {{"cmd", cmd}, {"target", target}, {"args", args}});
    }

private Q_SLOTS:
    void sessionNewCreatesDefaultWorkspaceAndSelects()
    {
        Store s;
        FakeTerminals t;
        QSignalSpy added(&s, &Store::sessionAdded);
        const auto r = call(s, t, "session.new", {}, {{"name", "api"}, {"cwd", QDir::tempPath()}});
        QVERIFY(r["ok"].toBool());
        QCOMPARE(added.count(), 1);
        QCOMPARE(s.workspaces.size(), 1);
        QCOMPARE(s.selected, r["result"]["id"].toString());
        QCOMPARE(s.session(s.selected)->cwd, QDir::tempPath());
    }

    void sessionNewRejectsMissingDirAndUnknownWorkspaceName()
    {
        Store s;
        FakeTerminals t;
        QVERIFY(!call(s, t, "session.new", {}, {{"cwd", "/definitely/not/here"}})["ok"].toBool());
        QVERIFY(!call(s, t, "session.new", {}, {{"workspaceName", "x"}})["ok"].toBool());
        QVERIFY(call(s, t, "session.new", {}, {{"workspaceName", "x"}, {"createWorkspace", true}})["ok"].toBool());
        QCOMPARE(s.workspaces.first().name, QStringLiteral("x"));
    }

    void targetsResolveByIdPrefixAndName()
    {
        Store s;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "alpha", {});
        s.addSession(ws, "beta", {});
        QString err;
        QCOMPARE(s.resolveSession(a, &err), a);
        QCOMPARE(s.resolveSession(a.left(6), &err), a);
        QCOMPARE(s.resolveSession("alpha", &err), a);
        QVERIFY(s.resolveSession("gamma", &err).isEmpty());
        QVERIFY(err.contains("no session"));
        QVERIFY(s.resolveSession({}, &err).isEmpty()); // nothing selected yet
    }

    void closingSelectedSelectsNeighbour()
    {
        Store s;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "a", {}), b = s.addSession(ws, "b", {}), c = s.addSession(ws, "c", {});
        s.select(b);
        s.removeSession(b);
        QCOMPARE(s.selected, c);
        s.removeSession(c);
        QCOMPARE(s.selected, a);
        s.removeSession(a);
        QVERIFY(s.selected.isEmpty());
    }

    void statusAndAttentionNavigation()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "a", {}), b = s.addSession(ws, "b", {}), c = s.addSession(ws, "c", {});
        s.select(a);
        QVERIFY(!call(s, t, "session.status", c, {{"status", "bogus"}})["ok"].toBool());
        QVERIFY(call(s, t, "session.status", c, {{"status", "blocked"}})["ok"].toBool());
        QString err;
        QCOMPARE(s.go("next-attention", &err), c);
        QCOMPARE(s.go("next", &err), a); // wraps
        QCOMPARE(s.go("prev", &err), c);
        s.keyPressed(c);
        QCOMPARE(s.session(c)->status, QStringLiteral("idle"));
        QVERIFY(s.go("next-attention", &err).isEmpty());
        Q_UNUSED(b);
    }

    void completedWithAutoResetClearsWhenViewed()
    {
        Store s;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "a", {}), b = s.addSession(ws, "b", {});
        s.select(a);
        s.setStatus(b, "completed", true);
        s.select(b);
        QCOMPARE(s.session(b)->status, QStringLiteral("idle"));
    }

    void typeTextAndLines()
    {
        Store s;
        FakeTerminals t;
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        QVERIFY(call(s, t, "session.type", id, {{"text", "ls\n"}})["ok"].toBool());
        QCOMPARE(t.typed, QStringLiteral("ls\n"));
        QCOMPARE(call(s, t, "session.text", id, {{"lines", 2}})["result"]["text"].toString(), QStringLiteral("b\nc"));
        QCOMPARE(call(s, t, "session.info", id)["result"]["session"]["pid"].toInt(), 42);
    }

    void jsonRoundTripDropsLiveState()
    {
        Store s;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "a", "/tmp");
        s.select(a);
        s.setStatus(a, "blocked");
        Store r;
        r.fromJson(s.toJson());
        QCOMPARE(r.selected, a);
        QCOMPARE(r.session(a)->cwd, QStringLiteral("/tmp"));
        QCOMPARE(r.session(a)->status, QStringLiteral("idle")); // a stale glyph must not outlive the run
    }

    void treeAndUnknownCommand()
    {
        Store s;
        FakeTerminals t;
        call(s, t, "session.new", {}, {{"name", "x"}});
        const auto tree = call(s, t, "tree")["result"]["tree"]["workspaces"].toArray();
        QCOMPARE(tree.size(), 1);
        QCOMPARE(tree[0]["sessions"][0]["name"].toString(), QStringLiteral("x"));
        QVERIFY(tree[0]["sessions"][0]["active"].toBool());
        QVERIFY(!call(s, t, "nope")["ok"].toBool());
        QVERIFY(call(s, t, "workspace.delete", "main")["ok"].toBool());
        QVERIFY(s.workspaces.isEmpty() && s.selected.isEmpty());
    }
};

QTEST_GUILESS_MAIN(TestCore)
#include "test_core.moc"
