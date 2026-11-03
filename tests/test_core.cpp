#include "control.h"
#include "launcher.h"
#include "store.h"

#include <QDir>
#include <QFileInfo>
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
        s.keyPressed(c, Store::Key::Plain);
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

    void statusResetFollowsTheSetting()
    {
        Store s;
        const QString a = s.addSession(s.addWorkspace("w"), {}, {});
        s.setStatus(a, "active");
        s.keyPressed(a, Store::Key::Plain);
        QCOMPARE(s.session(a)->status, QStringLiteral("active")); // typing while the agent works keeps the glyph
        s.keyPressed(a, Store::Key::Interrupt);
        QCOMPARE(s.session(a)->status, QStringLiteral("idle"));
        s.settings.statusReset = "enter";
        s.setStatus(a, "completed");
        s.keyPressed(a, Store::Key::Plain);
        QCOMPARE(s.session(a)->status, QStringLiteral("completed"));
        s.keyPressed(a, Store::Key::Submit);
        QCOMPARE(s.session(a)->status, QStringLiteral("idle"));
    }

    void namesComeFromTheProgramUntilPinned()
    {
        Store s;
        const QString a = s.addSession(s.addWorkspace("w"), {}, QDir::tempPath());
        QCOMPARE(s.session(a)->displayName(), QStringLiteral("New session"));
        s.setTitle(a, QString::fromUtf8("✳ Fix the login bug"));
        QCOMPARE(s.session(a)->displayName(), QStringLiteral("Fix the login bug"));
        s.renameSession(a, "pinned");
        s.setTitle(a, "later title");
        QCOMPARE(s.session(a)->displayName(), QStringLiteral("pinned"));
        s.renameSession(a, "");
        QCOMPARE(s.session(a)->displayName(), QStringLiteral("later title"));
        Store r;
        r.fromJson(s.toJson());
        QCOMPARE(r.session(a)->displayName(), QStringLiteral("later title")); // the agent's name survives a restart
    }

    void workspaceRemembersFolderForNewSessions()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("proj"), other = s.addWorkspace("other");
        const QString a = s.addSession(ws, {}, {});
        s.setCwd(a, QDir::tempPath());
        QCOMPARE(s.workspace(ws)->folder, QDir::tempPath());
        QCOMPARE(s.newSessionCwd(ws, {}), QDir::tempPath());
        QCOMPARE(s.newSessionCwd(other, {}), QDir::homePath());
        s.settings.newSessionDirectory = "home";
        QCOMPARE(s.newSessionCwd(ws, {}), QDir::homePath());
        s.settings.newSessionDirectory = "workspace";
        const auto r = call(s, t, "session.new", {}, {{"cwd", QDir::tempPath()}}); // a bare --cwd joins the workspace living there
        QCOMPARE(s.workspaceOf(r["result"]["id"].toString())->id, ws);
    }

    void moveFlagDuplicateAndMruReselection()
    {
        Store s;
        FakeTerminals t;
        const QString w1 = s.addWorkspace("a"), w2 = s.addWorkspace("b");
        const QString x = s.addSession(w1, {}, {}), y = s.addSession(w1, {}, {}), z = s.addSession(w2, {}, {});
        QVERIFY(call(s, t, "session.move", y, {{"workspace", "b"}, {"index", 0}})["ok"].toBool());
        QCOMPARE(s.workspace(w2)->sessions.first().id, y);
        QVERIFY(call(s, t, "session.flag", x, {{"mode", "on"}})["ok"].toBool());
        QVERIFY(s.session(x)->flagged);
        const QString copy = call(s, t, "session.duplicate", x)["result"]["id"].toString();
        QCOMPARE(s.workspace(w1)->sessions[1].id, copy);
        s.select(z);
        s.select(y);
        s.removeSession(y); // back to the most recent session in the same workspace, not the adjacent row
        QCOMPARE(s.selected, z);
    }

    void agentDetectionAndSpinnerStripping()
    {
        QCOMPARE(agentForArgv({"/usr/bin/claude", "--resume"}), QStringLiteral("claude"));
        QCOMPARE(agentForArgv({"node", "--max-old-space-size=4096", "/opt/codex/bin/codex"}), QStringLiteral("codex"));
        QCOMPARE(agentForArgv({"-zsh"}), QString());
        QCOMPARE(agentForGroup({{"bash", "run.sh"}, {"agy"}}), QStringLiteral("antigravity"));
        QCOMPARE(availableLaunchers("/a:/b", [](const QString &f) { return f == "/b/claude"; }), QStringList({"terminal", "claude"}));
        QCOMPARE(Store::stripTitleSpinner(QString::fromUtf8("✳ Claude Code")), QStringLiteral("Claude Code"));
        QCOMPARE(Store::stripTitleSpinner(QString::fromUtf8("⠋ build")), QStringLiteral("build"));
    }

    void splitShortcutsCreateTransposeAndHide()
    {
        Store s;
        const QString a = s.addSession(s.addWorkspace("w"), {}, {});
        s.toggleSplit(a, "vertical");
        QVERIFY(s.session(a)->hasSplit && s.session(a)->splitVisible);
        s.toggleSplit(a, "horizontal");
        QVERIFY(s.session(a)->splitVisible);
        QCOMPARE(s.session(a)->splitAxis, QStringLiteral("horizontal"));
        s.toggleSplit(a, "horizontal");
        QVERIFY(s.session(a)->hasSplit && !s.session(a)->splitVisible); // hidden, second shell kept
        s.toggleSplit(a, "vertical");
        QVERIFY(s.session(a)->splitVisible);
    }

    void reopenClosedRestoresNameDirAndPlace()
    {
        Store s;
        const QString ws = s.addWorkspace("w");
        s.addSession(ws, {}, {});
        const QString b = s.addSession(ws, "pinned", QDir::tempPath());
        s.addSession(ws, {}, {});
        s.removeSession(b);
        const QString again = s.reopenClosed();
        QCOMPARE(s.workspace(ws)->sessions[1].id, again);
        QCOMPARE(s.session(again)->displayName(), QStringLiteral("pinned"));
        QCOMPARE(s.session(again)->cwd, QDir::tempPath());
        QVERIFY(s.reopenClosed().isEmpty());
    }

    void companionsStayWithTheirParent()
    {
        Store s;
        FakeTerminals t;
        const QString w1 = s.addWorkspace("a"), w2 = s.addWorkspace("b");
        const QString p = s.addSession(w1, {}, QDir::tempPath()), other = s.addSession(w1, {}, {});
        const QString c1 = call(s, t, "session.new", {}, {{"parent", p}, {"name", "logs"}})["result"]["id"].toString();
        const QString c2 = s.addCompanion(c1, {}, {}); // a companion target means its parent
        QCOMPARE(s.session(c2)->parentId, p);
        QCOMPARE(s.session(c1)->cwd, QDir::tempPath());
        QStringList order;
        for (const auto &x : s.workspace(w1)->sessions)
            order << x.id;
        QCOMPARE(order, QStringList({p, c1, c2, other}));
        QVERIFY(!s.moveSession(c1, w2, -1)); // companions reorder only among themselves
        s.moveSession(c2, w1, 1);
        QCOMPARE(s.workspace(w1)->sessions[1].id, c2);
        s.moveSession(p, w2, -1); // the parent carries its group
        QCOMPARE(s.workspace(w2)->sessions.size(), 3);
        s.removeSession(p);
        QVERIFY(!s.session(c1) && !s.session(c2));
    }

    void tintRecolorsKeepsPlacementAndPersists()
    {
        Store s;
        FakeTerminals t;
        QVERIFY(!call(s, t, "workspace.new", {}, {{"tintOn", QJsonArray{"name"}}})["ok"].toBool());
        QVERIFY(!call(s, t, "workspace.new", {}, {{"tint", "pink"}})["ok"].toBool());
        QVERIFY(s.workspaces.isEmpty()); // a refused tint creates nothing
        const QString ws = call(s, t, "workspace.new", {}, {{"name", "prod"}, {"tint", "Red"}})["result"]["id"].toString();
        QCOMPARE(s.workspace(ws)->tint, (Tint{"red", {"icon"}}));
        const QString a = s.addSession(ws, {}, {});
        QVERIFY(s.session(a)->tint.color.isEmpty()); // a workspace tint never reaches its sessions
        s.placeTint(a, {"name"});
        QVERIFY(s.session(a)->tint.color.isEmpty()); // placing on an untinted row is a no-op
        QVERIFY(call(s, t, "session.tint", a, {{"mode", "set"}, {"tint", "green"}, {"tintOn", QJsonArray{"name", "icon"}}})["ok"].toBool());
        QVERIFY(call(s, t, "session.tint", a, {{"mode", "set"}, {"tint", "blue"}})["ok"].toBool());
        QCOMPARE(s.session(a)->tint, (Tint{"blue", {"icon", "name"}}));
        QVERIFY(!call(s, t, "session.tint", a, {{"mode", "clear"}, {"tint", "red"}})["ok"].toBool());
        QVERIFY(!call(s, t, "session.tint", a, {{"mode", "set"}, {"tint", "red"}, {"tintOn", QJsonArray{"glyph"}}})["ok"].toBool());
        const auto node = call(s, t, "tree")["result"]["tree"]["workspaces"][0];
        QCOMPARE(node["tint"].toString(), QStringLiteral("red"));
        QCOMPARE(node["sessions"][0]["tintOn"].toArray(), (QJsonArray{"icon", "name"}));
        QCOMPARE(s.session(s.duplicateSession(a, {}))->tint, Tint{}); // a duplicate starts untinted
        Store r;
        r.fromJson(s.toJson());
        QCOMPARE(r.session(a)->tint, (Tint{"blue", {"icon", "name"}}));
        QVERIFY(call(s, t, "session.tint", a, {{"mode", "clear"}})["ok"].toBool());
        QVERIFY(!call(s, t, "tree")["result"]["tree"]["workspaces"][0]["sessions"][0].toObject().contains("tint"));
    }

    void workspaceFocusFilterAndSuspend()
    {
        Store s;
        FakeTerminals t;
        const QString w1 = s.addWorkspace("a"), w2 = s.addWorkspace("b");
        const QString a1 = s.addSession(w1, {}, {}), a2 = s.addSession(w1, {}, {}), b1 = s.addSession(w2, {}, {});
        s.select(a2);
        s.select(b1);
        QVERIFY(call(s, t, "workspace.focus", "a", {{"mode", "add"}})["ok"].toBool());
        QVERIFY(!s.focusEnabled); // marking never narrows on its own
        QCOMPARE(s.selected, b1);
        QVERIFY(call(s, t, "workspace.filter", {}, {{"mode", "on"}})["ok"].toBool());
        QCOMPARE(s.selected, a2); // the narrowing hid b1: back to the most recent session still on screen
        QCOMPARE(s.visibleWorkspaces().size(), 1);
        QString err;
        QCOMPARE(s.go("next", &err), a1);
        QCOMPARE(s.go("next", &err), a2); // navigation wraps inside the filter
        const auto tree = call(s, t, "tree")["result"]["tree"];
        QVERIFY(tree["workspaceFilter"].toBool());
        QVERIFY(tree["workspaces"][0]["focused"].toBool());
        QVERIFY(!tree["workspaces"][1].toObject().contains("focused"));
        const QString w3 = s.addWorkspace("c"); // created under the filter, so it joins the set
        QVERIFY(s.focused.contains(w3));
        s.select(b1);
        QVERIFY(!s.focusEnabled && s.focused.size() == 2); // selecting outside suspends, the set stays
        Store r;
        r.fromJson(s.toJson());
        QCOMPARE(r.focused, s.focused);
        s.removeWorkspace(w3);
        s.focusWorkspace(w1, "toggle");
        QVERIFY(s.isSoleFocus(w1));
        s.focusWorkspace(w1, "toggle");
        QVERIFY(s.focused.isEmpty() && !s.focusEnabled);
        s.setFilter(true);
        QVERIFY(!s.focusEnabled); // an empty set is never applied
        QVERIFY(!call(s, t, "workspace.focus", "a", {{"mode", "sideways"}})["ok"].toBool());
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
