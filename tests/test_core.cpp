#include "control.h"
#include "hooks.h"
#include "keymap.h"
#include "launcher.h"
#include "restore.h"
#include "store.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QSignalSpy>
#include <QTest>
#include <QUuid>

class FakeTerminals : public Terminals
{
public:
    QString typed;
    QString screen = QStringLiteral("a\nb\nc\n\n");
    bool type(const QString &, const QString &text, QString *) override { return typed += text, true; }
    QString scrollback = QStringLiteral("old\na\nb\nc\n  \n");
    QString lastPane;
    QString text(const QString &, const QString &pane, bool history, QString *) override { return lastPane = pane, history ? scrollback : screen; }
    QHash<QString, QStringList> panes; // session -> pane ids
    QStringList paneIds(const QString &id) const override { return panes.value(id); }
    QList<QJsonObject> events;
    void emitEvent(const QString &kind, const QString &id, const QJsonObject &payload) override { events << QJsonObject{{"kind", kind}, {"session", id}, {"payload", payload}}; }
    QJsonObject info(const QString &) override { return {{"pid", 42}}; }
    QString appCmd;
    QJsonObject appArgs;
    bool appCommand(const QString &cmd, const QString &, const QJsonObject &args, QJsonObject *, QString *) override
    {
        appCmd = cmd;
        appArgs = args;
        return true;
    }
    QJsonObject sessionExtras(const QString &) const override { return {{"overlay", true}}; }
    QHash<QString, QStringList> argv; // pane -> foreground argv
    QStringList foregroundArgv(const QString &, const QString &pane) override { return argv.value(pane); }
    QString refuse; // the pane panePlan refuses
    bool panePlan(const QString &, const QString &pane, PanePlan *out, QString *error) override
    {
        if (pane == refuse)
            return *error = pane + " refused", false;
        *out = {QDir::tempPath(), pane == "right" ? "exec 'top'" : ""};
        return true;
    }
};

class TestCore : public QObject
{
    Q_OBJECT

    const QJsonObject call(Store &s, FakeTerminals &t, const QString &cmd, const QString &target = {}, const QJsonObject &args = {})
    {
        return dispatch(s, t, {{"cmd", cmd}, {"target", target}, {"args", args}});
    }

private Q_SLOTS:

    void configDirectoryFollowsSettingThenStateDirThenHome()
    {
        QCOMPARE(configDirectory("/x", "/state", "/home/u"), QStringLiteral("/x"));
        QCOMPARE(configDirectory({}, "/state", "/home/u"), QStringLiteral("/state/config"));
        QCOMPARE(configDirectory({}, {}, "/home/u"), QStringLiteral("/home/u/.config/agterm-qt"));
    }

    void chordsMapMacWordsByTheReadmeTable()
    {
        QString e;
        QCOMPARE(parseChordToken("cmd+o", &e), QStringList{"Ctrl+Shift+O"});
        QCOMPARE(parseChordToken("cmd+shift+d", &e), QStringList{"Ctrl+Alt+Shift+D"});
        QCOMPARE(parseChordToken("cmd+opt+up", &e), QStringList{"Ctrl+Alt+Shift+Up"});
        QCOMPARE(parseChordToken("ctrl+opt+down", &e), QStringList{"Ctrl+Alt+Down"});
        QCOMPARE(parseChordToken("ctrl+shift+/", &e), QStringList{"Ctrl+Shift+?"});
        QCOMPARE(parseChordToken("ctrl+a>g|f5", &e), (QStringList{"Ctrl+A, G", "F5"}));
        QVERIFY(parseChordToken("g", &e).isEmpty() && e.contains("modifier"));
        QVERIFY(parseChordToken("ctrl+bogus", &e).isEmpty() && e.contains("invalid chord"));
    }

    void keymapRebindsCollidesAndDiagnoses()
    {
        const QMap<QString, QStringList> defaults{{"new_session", {"Shift+Ctrl+N"}}, {"toggle_split", {"Ctrl+Shift+D"}}, {"select_theme", {}}};
        const Keymap km = parseKeymap(QStringLiteral("# comment\n"
                                                     "map ctrl+alt+l toggle_split\n"
                                                     "map ctrl+shift+n select_theme   # taken by new_session\n"
                                                     "map ctrl+alt+j toggle_scratch\n"
                                                     "map ctrl+alt+k bogus\n"
                                                     "command \"Edit\" ctrl+a>e --error-hud --error-position top kate \"$AGT_SESSION_PWD\" # c\n"
                                                     "command \"Plain\" [ -f x ] && echo y\n"
                                                     "command \"Edit\" ctrl+alt+e true\n"
                                                     "command \"Clash\" ctrl+alt+l true\n"
                                                     "command \"Bad\" --error-pane left true\n"
                                                     "global-hotkey ctrl+space\n"
                                                     "frobnicate\n"),
                                      defaults);
        QCOMPARE(km.bindings.value("toggle_split"), QStringList{"Ctrl+Alt+L"}); // the default is gone
        QCOMPARE(km.bindings.value("new_session"), QStringList{"Ctrl+Shift+N"});
        QVERIFY(km.bindings.value("select_theme").isEmpty());
        QCOMPARE(km.raw.value("toggle_split"), QStringLiteral("ctrl+alt+l"));
        QCOMPARE(km.commands.size(), 3);
        QCOMPARE(km.commands[0].keys, QStringList{"Ctrl+A, E"});
        QVERIFY(km.commands[0].errorHud);
        QCOMPARE(km.commands[0].errorPosition, QStringLiteral("top-center"));
        QCOMPARE(km.commands[0].command, QStringLiteral("kate \"$AGT_SESSION_PWD\""));
        QVERIFY(km.commands[1].keys.isEmpty());
        QCOMPARE(km.commands[1].command, QStringLiteral("[ -f x ] && echo y"));
        QVERIFY(km.commands[2].keys.isEmpty()); // collided with toggle_split's new chord
        QStringList messages;
        for (const auto &d : km.diagnostics)
            messages << QString::number(d.line) + ":" + d.message;
        const QString all = messages.join('\n');
        QVERIFY2(all.contains("3:chord 'Ctrl+Shift+N' conflicts with built-in 'new_session'"), qPrintable(all));
        QVERIFY2(all.contains("4:action 'toggle_scratch' is not available in agterm-qt"), qPrintable(all));
        QVERIFY2(all.contains("5:unknown action 'bogus'"), qPrintable(all));
        QVERIFY2(all.contains("8:command 'Edit' is already defined"), qPrintable(all));
        QVERIFY2(all.contains("9:custom command 'Clash' shortcut 'Ctrl+Alt+L' conflicts with built-in 'toggle_split'"), qPrintable(all));
        QVERIFY2(all.contains("10:command 'Bad' requires --error-hud"), qPrintable(all));
        QVERIFY2(all.contains("11:global-hotkey"), qPrintable(all));
        QVERIFY2(all.contains("12:unknown verb 'frobnicate'"), qPrintable(all));
        // a starter written from the defaults parses clean and changes nothing
        const Keymap starter = parseKeymap(starterKeymap(defaults), defaults);
        QVERIFY(starter.diagnostics.isEmpty());
        QCOMPARE(starter.bindings.value("new_session"), QStringList{"Ctrl+Shift+N"});
    }

    void tokensExpandRaw()
    {
        QCOMPARE(expandTokens("open {AGT_SESSION_PWD} {AGT_NOPE} {AGT_PANE}", {{"AGT_SESSION_PWD", "/tmp"}}), QStringLiteral("open /tmp {AGT_NOPE} "));
    }

    void hooksParseKindsAndDuplicates()
    {
        QList<KeymapDiagnostic> d;
        const auto hooks = parseHooks("on status echo # kept verbatim\non bogus x\non notify\nmap x y\non status echo # kept verbatim\non tree.changed true\n", &d);
        QCOMPARE(hooks.size(), 2);
        QCOMPARE(hooks[0].command, QStringLiteral("echo # kept verbatim"));
        QCOMPARE(hooks[1].line, 6);
        QCOMPARE(d.size(), 4);
        QVERIFY(d[0].message.contains("unknown event kind 'bogus'"));
        QVERIFY(d[1].message.contains("no shell line"));
        QVERIFY(d[2].message.contains("unknown verb 'map'"));
        QVERIFY(d[3].message.contains("already defined"));
        QList<KeymapDiagnostic> none;
        QVERIFY(parseHooks(starterHooks(), &none).isEmpty() && none.isEmpty());
    }

    void hooksRunWithTheEventOnStdinAndReportFailures()
    {
        QTemporaryDir dir;
        const QString out = dir.filePath("out");
        QFile conf(dir.filePath("hooks.conf"));
        QVERIFY(conf.open(QIODevice::WriteOnly));
        conf.write(QStringLiteral("on status cat >> '%1'; echo \"$AGT_EVENT_STATUS $AGT_SESSION_ID $AGT_SOCKET\" >> '%1'\non status exit 3\n").arg(out).toUtf8());
        conf.close();
        Store s;
        EventSource events(s);
        HookRunner hooks;
        hooks.socket = "/tmp/sock";
        QSignalSpy failed(&hooks, &HookRunner::failed);
        QCOMPARE(hooks.load(conf.fileName()), 0);
        connect(&events, &EventSource::event, &hooks, &HookRunner::fire);
        const QString id = s.addSession(s.addWorkspace("w"), {}, {});
        s.setStatus(id, "blocked");
        s.setStatus(id, "completed");
        QTRY_COMPARE(failed.size(), 1); // one banner until the hook next succeeds
        QTRY_VERIFY(QFile(out).size() > 0 && QFile::exists(out));
        QTRY_VERIFY([&] {
            QFile f(out);
            return f.open(QIODevice::ReadOnly) && f.readAll().count('\n') == 4;
        }());
        QFile f(out);
        QVERIFY(f.open(QIODevice::ReadOnly));
        const QList<QByteArray> lines = f.readAll().split('\n');
        const QJsonObject e = QJsonDocument::fromJson(lines[0]).object();
        QCOMPARE(e["kind"].toString(), QStringLiteral("status"));
        QCOMPARE(e["session"].toString(), id);
        QCOMPARE(e["payload"]["previous"].toString(), QStringLiteral("idle"));
        QCOMPARE(lines[1], QByteArray("blocked ") + id.toUtf8() + " /tmp/sock");
        QCOMPARE(QJsonDocument::fromJson(lines[2]).object()["payload"].toObject()["previous"].toString(), QStringLiteral("blocked"));
        QTRY_VERIFY(hooks.list()["hooks"].toArray()[1].toObject()["lastFailure"].toString().contains("exit status 3"));
        QCOMPARE(failed.size(), 1);
    }

    void settingsRoundTripByMasterNames()
    {
        Settings a;
        a.theme = "DarkPastels";
        a.fontSize = 13;
        a.notificationsEnabled = false;
        a.hiddenInterfaceElements = {"split"};
        a.shownInterfaceElements = {"workspaceName"};
        const QJsonObject o = a.toJson();
        QCOMPARE(o["theme"].toString(), QStringLiteral("DarkPastels"));
        const Settings b = Settings::fromJson(o);
        QCOMPARE(b.theme, a.theme);
        QCOMPARE(b.fontSize, 13.0);
        QVERIFY(!b.notificationsEnabled && b.closeUndo);
        QVERIFY(!b.shows("split") && b.shows("sessionName") && b.shows("workspaceName") && !b.shows("customCommands"));
        QVERIFY(Settings::fromJson({}).closeUndo); // an old file keeps the defaults
    }
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
        QCOMPARE(s.go("next-attention", &err), c); // nothing needs attention: the selection stays, as master
        QCOMPARE(s.go("previous", &err), b);
        QVERIFY(s.go("sideways", &err).isEmpty());
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

    void undoCloseRestoresInPlaceWithinTheGrace()
    {
        Store s;
        FakeTerminals t;
        s.graceMs = 50;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, {}, {}), p = s.addSession(ws, "parent", {}), c = s.addCompanion(p, {}, {});
        s.select(a);
        s.select(p);
        QSignalSpy removed(&s, &Store::sessionRemoved);
        QVERIFY(s.softClose({p}));
        QVERIFY(!s.session(p) && !s.session(c)); // the group leaves the tree
        QCOMPARE(s.selected, a);
        QCOMPARE(removed.count(), 0); // the terminals live on through the grace
        QVERIFY(s.undoClose());
        QStringList order;
        for (const auto &x : s.workspace(ws)->sessions)
            order << x.id;
        QCOMPARE(order, QStringList({a, p, c}));
        QCOMPARE(s.selected, p);
        QVERIFY(!s.undoClose());

        const auto r = call(s, t, "session.close", c, {{"undoable", true}});
        QVERIFY(r["result"]["undoable"].toBool());
        QTRY_COMPARE(removed.count(), 1); // the grace expired: final, and reopenable
        QVERIFY(!s.undoClose());
        QCOMPARE(s.closed.size(), 1);
        s.settings.closeUndo = false;
        QVERIFY(!call(s, t, "session.close", a, {{"undoable", true}})["result"]["undoable"].toBool());
        QVERIFY(!s.session(a));

        const QString other = s.addWorkspace("other");
        s.focusWorkspace(ws, "add");
        QVERIFY(s.softRemoveWorkspace(ws));
        QCOMPARE(s.workspaces.size(), 1);
        QVERIFY(s.focused.isEmpty());
        QVERIFY(s.undoClose());
        QCOMPARE(s.workspaces.first().id, ws);
        QVERIFY(s.focused.contains(ws));
        Q_UNUSED(other);
    }

    void duplicateAsCompanionCopiesTheLayout()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w");
        const QString src = s.addSession(ws, {}, {});
        s.select(src);
        s.setSplit(src, true, false, "horizontal");
        s.session(src)->splitRatio = 0.3;
        t.refuse = "right";
        QVERIFY(!call(s, t, "session.companion.duplicate", src)["ok"].toBool());
        QCOMPARE(s.workspace(ws)->sessions.size(), 1); // one refused pane creates nothing
        t.refuse.clear();
        QSignalSpy layout(&s, &Store::paneLayoutChanged);
        const auto r = call(s, t, "session.companion.duplicate", src, {{"noSelect", true}});
        const Session *copy = s.session(r["result"]["id"].toString());
        QCOMPARE(r["result"]["parent"].toString(), src);
        QCOMPARE(copy->cwd, QDir::tempPath());
        QVERIFY(copy->command.isEmpty()); // a shell in the left pane gives a plain shell
        QVERIFY(copy->hasSplit && copy->splitVisible);
        QCOMPARE(copy->splitAxis, QStringLiteral("horizontal"));
        QCOMPARE(copy->splitRatio, 0.3);
        QCOMPARE(copy->splitCommand, QStringLiteral("exec 'top'"));
        QCOMPARE(layout.count(), 1);
        QCOMPARE(s.selected, src);
    }

    void overlayAndHudArgumentsFollowMaster()
    {
        Store s;
        FakeTerminals t;
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        auto error = [&](const QString &cmd, const QJsonObject &args) { return call(s, t, cmd, id, args)["error"].toString(); };
        QCOMPARE(error("session.overlay.open", {}), QStringLiteral("session.overlay.open requires a command"));
        QCOMPARE(error("session.overlay.open", {{"command", "top"}, {"sizePercent", 0}}), QStringLiteral("session.overlay.open: --size-percent must be 1...100"));
        QCOMPARE(error("session.overlay.open", {{"command", "top"}, {"sizePercent", 50}, {"pane", "left"}}),
                 QStringLiteral("session.overlay.open: --pane is mutually exclusive with --size-percent"));
        QCOMPARE(error("session.overlay.open", {{"command", "top"}, {"color", "red"}}), QStringLiteral("invalid color: red (#rrggbb)"));
        QVERIFY(error("session.overlay.open", {{"html", "x.html"}}).contains("qt6-webengine-dev"));
        QCOMPARE(error("session.overlay.open", {{"command", "top"}, {"pane", "right"}}), QStringLiteral("session has no split"));
        QCOMPARE(error("session.overlay.resize", {}), QStringLiteral("session.overlay.resize requires --size-percent, --width/--height or --full"));
        QCOMPARE(error("session.overlay.resize", {{"full", true}, {"sizePercent", 40}}),
                 QStringLiteral("session.overlay.resize: --full is mutually exclusive with --size-percent"));
        QCOMPARE(error("session.hud.open", {}), QStringLiteral("session.hud.open requires a message"));
        QCOMPARE(error("session.hud.open", {{"message", "a\nb"}}), QStringLiteral("hud text must not contain control characters"));
        QCOMPARE(error("session.hud.open", {{"message", QString(257, 'x')}}), QStringLiteral("hud message too long (max 256 characters)"));
        QCOMPARE(error("session.hud.open", {{"message", "m"}, {"fontSize", 5}}), QStringLiteral("session.hud.open: --font-size must be 6...72 points"));
        QCOMPARE(error("session.hud.update", {{"message", "m"}, {"fontSize", 12}}),
                 QStringLiteral("session.hud.update: --font-size is fixed at open; reopen the hud to change it"));
        QCOMPARE(error("session.hud.open", {{"message", "m"}, {"hideAfter", 90000}}), QStringLiteral("session.hud.open: --hide-after must be 0...86400 seconds"));
        QVERIFY(error("session.hud.open", {{"message", "m"}, {"position", "middle"}}).startsWith("invalid position: middle"));
        QVERIFY(error("session.hud.open", {{"message", "m"}, {"spinner", "wheel"}}).startsWith("invalid spinner: wheel"));

        QVERIFY(call(s, t, "session.hud.open", id, {{"message", "a\nb"}, {"markdown", true}, {"position", "top"}, {"spinner", true}, {"pane", "primary"}})["ok"].toBool());
        QCOMPARE(t.appCmd, QStringLiteral("session.hud.open"));
        QCOMPARE(t.appArgs["position"].toString(), QStringLiteral("top-center"));
        QCOMPARE(t.appArgs["spinner"].toString(), QStringLiteral("bar"));
        QCOMPARE(t.appArgs["pane"].toString(), QStringLiteral("left"));
        QVERIFY(call(s, t, "session.overlay.open", id, {{"command", "top"}, {"follow", true}})["ok"].toBool());
        QVERIFY(call(s, t, "tree")["result"]["tree"]["workspaces"][0]["sessions"][0]["overlay"].toBool()); // the app's read-back joins the node
    }

    void restoreCapturesProgramsNotIdleShellsAndReplaysOnce()
    {
        QCOMPARE(Restore::captured({"-zsh"}, "/bin/zsh"), QStringList());
        QCOMPARE(Restore::captured({"/usr/bin/fish", "-l", "-i"}, "/bin/bash"), QStringList());
        QCOMPARE(Restore::captured({"bash", "script.sh"}, "/bin/bash"), (QStringList{"bash", "script.sh"}));
        QCOMPARE(Restore::captured({"-myshell"}, "/opt/myshell"), QStringList());
        QCOMPARE(Restore::captured({"claude", "--resume"}, "/bin/bash"), (QStringList{"claude", "--resume"}));
        const QStringList deny = Restore::parseDenylist(QString::fromUtf8(Restore::starterDenylist));
        QCOMPARE(deny, (QStringList{"tmux", "screen", "zellij"}));
        QVERIFY(!Restore::shouldRestore({"/usr/bin/tmux", "attach"}, deny));
        QVERIFY(!Restore::shouldRestore({"vim", "a\tb"}, deny));
        QVERIFY(Restore::shouldRestore({"vim", "it's"}, deny));
        QCOMPARE(Restore::shellQuoted({"vim", "it's"}), QStringLiteral("'vim' 'it'\\''s'"));

        Store s;
        FakeTerminals t;
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        t.argv.insert("main", {"htop", "-d", "5"});
        QCOMPARE(call(s, t, "restore.capture")["error"].toString(), QStringLiteral("restore.capture requires rerun mode; configured restore mode is none"));
        QCOMPARE(call(s, t, "restore.mode", {}, {{"mode", "sometimes"}})["error"].toString(), QStringLiteral("invalid restore mode: sometimes"));
        const QJsonObject mode = call(s, t, "restore.mode", {}, {{"mode", "rerun"}})["result"]["restore"].toObject();
        QCOMPARE(mode["configured"].toString(), QStringLiteral("rerun"));
        QVERIFY(mode["restartRequired"].toBool());
        QCOMPARE(call(s, t, "restore.capture")["result"]["count"].toInt(), 1);

        Store next;
        next.fromJson(s.toJson());
        QCOMPARE(next.restoreModeAtLaunch, QStringLiteral("rerun"));
        QCOMPARE(next.takeReplay(id, false, deny), QStringLiteral("'htop' '-d' '5'"));
        QCOMPARE(next.takeReplay(id, false, deny), QString()); // consumed
        QVERIFY(!next.toJson()["workspaces"][0]["sessions"][0].toObject().contains("foregroundCommand"));

        QCOMPARE(call(s, t, "session.restore", id, {{"mode", "set"}, {"command", "a\tb"}})["error"].toString(),
                 QStringLiteral("command must not contain control characters"));
        QCOMPARE(call(s, t, "session.restore", id, {{"mode", "set"}, {"pane", "right"}, {"command", "x"}})["error"].toString(), QStringLiteral("session has no split"));
        QVERIFY(call(s, t, "session.restore", id, {{"mode", "set"}, {"command", "tmux attach"}})["ok"].toBool());
        QCOMPARE(call(s, t, "session.info", id)["result"]["session"]["restoreCommand"].toString(), QStringLiteral("tmux attach"));
        Store pinned;
        pinned.fromJson(s.toJson());
        QCOMPARE(pinned.takeReplay(id, false, deny), QStringLiteral("tmux attach")); // a pin beats the capture and the denylist
        QVERIFY(call(s, t, "restore.clear")["ok"].toBool());
        QVERIFY(s.session(id)->foreground.isEmpty());
        QCOMPARE(call(s, t, "restore.mode", {}, {{"mode", "live"}})["result"]["restore"]["active"].toString(), QStringLiteral("none"));
    }

    void dashboardTargetsExpandDropAndTrim()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w");
        QStringList ids;
        for (int i = 0; i < 10; ++i)
            ids << s.addSession(ws, QStringLiteral("s%1").arg(i), {});
        s.setSplit(ids[0], true, false, "vertical"); // a hidden split still gets its cell
        QString notes, error;
        QCOMPARE(dashboardCells(s, {ids[0], ids[1] + ":RIGHT", ids[1] + ":top", ids[0] + ":left"}, false, &notes, &error),
                 (QStringList{ids[0] + ":left", ids[0] + ":right", ids[1] + ":left"}));
        QVERIFY(notes.contains("has no split"));
        dashboardCells(s, {ids[0] + ":scratch"}, false, &notes, &error);
        QCOMPARE(error, QStringLiteral("dashboard: invalid session id '%1:scratch' — use <id>, <id>:left, or <id>:right").arg(ids[0]));
        error.clear();
        QCOMPARE(dashboardCells(s, ids, false, &notes, &error).size(), 9);
        QCOMPARE(notes, QStringLiteral("dropped 2 pane(s) beyond the 9-cell limit"));
        QCOMPARE(dashboardGrid(5), (std::pair<int, int>{3, 2}));
        QCOMPARE(dashboardGrid(4), (std::pair<int, int>{2, 2}));
        QCOMPARE(dashboardFontFactor(3, 2), 0.62);
        auto err = [&](const QJsonObject &args) { return call(s, t, "dashboard", {}, args)["error"].toString(); };
        QCOMPARE(err({}), QStringLiteral("dashboard requires at least one session id"));
        QCOMPARE(err({{"mru", true}}), QStringLiteral("no recent sessions"));
        QCOMPARE(err({{"close", true}, {"mru", true}}), QStringLiteral("dashboard --close takes no ids, --mru, or font options"));
        QCOMPARE(err({{"targets", QJsonArray{ids[0]}}, {"fontSize", 10}, {"autoSize", true}}), QStringLiteral("dashboard: --font-size is mutually exclusive with --auto-size"));
        QCOMPARE(err({{"targets", QJsonArray{ids[0]}}, {"fontSize", -1}}), QStringLiteral("dashboard --font-size must be a positive number"));
        s.select(ids[2]);
        QCOMPARE(err({{"targets", QJsonArray{ids[0]}}, {"mru", true}}), QStringLiteral("dashboard --mru cannot be combined with explicit session ids"));
        QVERIFY(call(s, t, "dashboard", {}, {{"mru", true}, {"autoSize", true}})["ok"].toBool());
        QCOMPARE(t.appArgs["cells"].toArray(), (QJsonArray{ids[2] + ":left"}));
        QCOMPARE(t.appArgs["fontMode"].toString(), QStringLiteral("auto"));
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

    void eventsReadWalksTheRing()
    {
        Store s;
        FakeTerminals t;
        EventSource events(s);
        const QJsonObject boot = call(s, t, "events.read")["result"]["events"].toObject();
        QVERIFY(boot["items"].toArray().isEmpty()); // subscribe from now
        const QString run = boot["run"].toString();
        const qint64 next = boot["next"].toInteger();
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        s.setStatus(id, "blocked");
        QJsonObject r = call(s, t, "events.read", {}, {{"run", run}, {"after", QString::number(next)}, {"kinds", QJsonArray{"status"}}});
        QCOMPARE(std::as_const(r)["result"]["events"]["items"].toArray().size(), 1);
        QCOMPARE(std::as_const(r)["result"]["events"]["items"][0]["payload"]["status"].toString(), QStringLiteral("blocked"));
        r = call(s, t, "events.read", {}, {{"run", run}, {"after", QString::number(next)}, {"limit", 1}});
        QCOMPARE(std::as_const(r)["result"]["events"]["items"][0]["kind"].toString(), QStringLiteral("session.created"));
        QCOMPARE(std::as_const(r)["result"]["events"]["next"].toInteger(), std::as_const(r)["result"]["events"]["items"][0]["seq"].toInteger());
        QCOMPARE(call(s, t, "events.read", {}, {{"run", run}})["error"].toString(), QStringLiteral("events.read requires --run and --after together"));
        QCOMPARE(call(s, t, "events.read", {}, {{"kinds", QJsonArray{"bogus"}}})["error"].toString(), QStringLiteral("invalid event kind: bogus"));
        QCOMPARE(call(s, t, "events.read", {}, {{"limit", 0}})["error"].toString(), QStringLiteral("event limit must be between 1 and 1000"));
        QCOMPARE(call(s, t, "events.read", {}, {{"run", run}, {"after", "999999999"}})["error"].toString(),
                 QStringLiteral("event cursor is ahead of the current sequence"));
        QCOMPARE(call(s, t, "events.read", {}, {{"run", QUuid::createUuid().toString(QUuid::WithoutBraces)}, {"after", "0"}})["error"].toString(),
                 QStringLiteral("event run changed"));
    }

    void sessionTextExtents()
    {
        Store s;
        FakeTerminals t;
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        QCOMPARE(call(s, t, "session.text", id)["result"]["text"].toString(), t.screen); // the visible screen
        QCOMPARE(call(s, t, "session.text", id, {{"all", true}})["result"]["text"].toString(), t.scrollback);
        QCOMPARE(call(s, t, "session.text", id, {{"lines", 4}})["result"]["text"].toString(), QStringLiteral("old\na\nb\nc"));
        QCOMPARE(call(s, t, "session.text", id, {{"all", true}, {"lines", 1}})["error"].toString(), QStringLiteral("use either --all or --lines, not both"));
        QCOMPARE(call(s, t, "session.text", id, {{"lines", 0}})["error"].toString(), QStringLiteral("--lines must be greater than 0"));
        QCOMPARE(call(s, t, "session.text", id, {{"pane", "split"}})["error"].toString(), QStringLiteral("session has no split pane"));
        QCOMPARE(call(s, t, "session.text", id, {{"pane", "up"}})["error"].toString(), QStringLiteral("invalid pane: up"));
        QCOMPARE(call(s, t, "session.text", id, {{"pane", "top"}})["result"]["pane"].toString(), QStringLiteral("left"));
    }

    void contextFlagCollapseAndWorkspaceGo()
    {
        Store s;
        FakeTerminals t;
        const QString a = s.addWorkspace("a"), b = s.addWorkspace("b");
        const QString a1 = s.addSession(a, "a1", {}), a2 = s.addSession(a, "a2", {}), b1 = s.addSession(b, "b1", {});
        s.select(a1);
        QCOMPARE(call(s, t, "session.context", a1, {{"mode", "set"}, {"text", "  PR #12  "}})["ok"].toBool(), true);
        QCOMPARE(call(s, t, "tree")["result"]["tree"]["workspaces"][0]["sessions"][0]["context"].toString(), QStringLiteral("PR #12"));
        QCOMPARE(call(s, t, "session.context", a1, {{"mode", "set"}, {"text", "a\nb"}})["error"].toString(),
                 QStringLiteral("context must not contain control characters or line breaks"));
        QCOMPARE(call(s, t, "session.context", a1, {{"mode", "set"}, {"text", "   "}})["error"].toString(),
                 QStringLiteral("context must not be empty (use --clear to remove it)"));
        QCOMPARE(call(s, t, "session.context", a1, {{"mode", "clear"}, {"text", "x"}})["error"].toString(), QStringLiteral("session.context clear takes no text"));
        QCOMPARE(call(s, t, "session.context", a1, {})["error"].toString(), QStringLiteral("invalid context mode:  (set|clear)"));
        QVERIFY(call(s, t, "session.context", a1, {{"mode", "clear"}})["ok"].toBool());
        QVERIFY(s.session(a1)->context.isEmpty());

        QVERIFY(call(s, t, "workspace.flag", a)["ok"].toBool());
        QVERIFY(s.session(a1)->flagged && s.session(a2)->flagged);
        QVERIFY(call(s, t, "workspace.flag", a)["ok"].toBool()); // all flagged: toggle unflags
        QVERIFY(!s.session(a1)->flagged);
        QCOMPARE(call(s, t, "workspace.flag", a, {{"mode", "maybe"}})["error"].toString(), QStringLiteral("invalid workspace flag mode: maybe"));

        QVERIFY(call(s, t, "workspace.collapse", b)["ok"].toBool());
        QVERIFY(call(s, t, "tree")["result"]["tree"]["workspaces"][1]["collapsed"].toBool());
        QVERIFY(call(s, t, "workspace.expand", b)["ok"].toBool());
        QVERIFY(!call(s, t, "tree")["result"]["tree"]["workspaces"][1].toObject().contains("collapsed"));
        QCOMPARE(call(s, t, "session.collapse", a2)["error"].toString(), QStringLiteral("session has no companions"));
        s.addCompanion(a1, {}, {});
        QVERIFY(call(s, t, "session.collapse", a1)["ok"].toBool());
        QVERIFY(call(s, t, "session.info", a1)["result"]["session"]["collapsed"].toBool());

        QCOMPARE(call(s, t, "workspace.go", {}, {{"to", "next"}})["result"]["id"].toString(), b);
        QCOMPARE(s.selected, b1);
        QCOMPARE(call(s, t, "workspace.go", {}, {{"to", "next"}})["result"]["id"].toString(), a); // wraps
        QCOMPARE(call(s, t, "workspace.go", {}, {{"to", "up"}})["error"].toString(), QStringLiteral("workspace.go requires --to next|prev"));
        s.flaggedView = true;
        QCOMPARE(call(s, t, "workspace.go", {}, {{"to", "prev"}})["error"].toString(), QStringLiteral("no other workspace to navigate to"));
    }

    void sidebarResizeRecentAndCompanions()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w"), other = s.addWorkspace("o");
        const QString id = s.addSession(ws, "one", "/tmp");
        s.select(id);
        QCOMPARE(call(s, t, "sidebar.mode", {}, {{"mode", "flagged"}})["result"]["sidebarMode"].toString(), QStringLiteral("flagged"));
        QVERIFY(s.flaggedView);
        QVERIFY(call(s, t, "sidebar.mode")["ok"].toBool()); // toggle
        QVERIFY(!s.flaggedView);
        QCOMPARE(call(s, t, "sidebar.flagged-layout")["result"]["text"].toString(), QStringLiteral("tree"));
        QCOMPARE(call(s, t, "tree")["result"]["tree"]["sidebarFlaggedLayout"].toString(), QStringLiteral("tree"));
        QCOMPARE(call(s, t, "sidebar.flagged-layout", {}, {{"mode", "x"}})["error"].toString(), QStringLiteral("invalid flagged layout: x"));
        QVERIFY(call(s, t, "sidebar.collapse")["ok"].toBool());
        QVERIFY(s.collapsed.contains(other) && !s.collapsed.contains(ws)); // the current workspace stays open
        QVERIFY(call(s, t, "sidebar.expand")["ok"].toBool());
        QVERIFY(s.collapsed.isEmpty());

        QCOMPARE(call(s, t, "session.resize", id, {{"ratio", 0.3}})["error"].toString(), QStringLiteral("session has no split"));
        s.setSplit(id, true, true, "vertical");
        QCOMPARE(call(s, t, "session.resize", id, {{"ratio", 0.99}})["result"]["ratio"].toDouble(), 0.95);
        QCOMPARE(call(s, t, "session.resize", id, {{"ratioDelta", -0.25}})["result"]["ratio"].toDouble(), 0.70);
        QCOMPARE(call(s, t, "session.resize", id)["error"].toString(), QStringLiteral("session.resize requires --split-ratio, --grow-left, or --grow-right"));

        QCOMPARE(call(s, t, "session.companion.new", id, {{"workspace", other}})["error"].toString(),
                 QStringLiteral("a companion takes no workspace or placement: it lands under its parent"));
        QCOMPARE(call(s, t, "session.companion.new", id, {{"wait", true}})["error"].toString(), QStringLiteral("--wait requires --command"));
        const QJsonObject c = call(s, t, "session.companion.new", id, {{"noSelect", true}})["result"].toObject();
        QCOMPARE(c["parent"].toString(), id);

        QVERIFY(call(s, t, "session.close", c["id"].toString())["ok"].toBool());
        const QJsonArray recent = call(s, t, "recent.list")["result"]["recent"].toArray();
        QCOMPARE(recent.size(), 1);
        QCOMPARE(recent[0]["id"].toString(), c["id"].toString());
        QCOMPARE(call(s, t, "recent.list", "x")["error"].toString(), QStringLiteral("recent.list takes no target or --window"));
        QCOMPARE(call(s, t, "recent.open", "zzz")["error"].toString(), QStringLiteral("no such recent item: zzz"));
        QVERIFY(call(s, t, "recent.open", c["id"].toString().left(6))["ok"].toBool());
        QVERIFY(call(s, t, "recent.list")["result"]["recent"].toArray().isEmpty());
        QCOMPARE(call(s, t, "recent.open")["error"].toString(), QStringLiteral("no recently closed items"));
        QVERIFY(call(s, t, "recent.clear")["ok"].toBool());

        QCOMPARE(call(s, t, "notify", id, {{"title", "t"}})["error"].toString(), QStringLiteral("notify requires a body"));
    }

    void batchCloseAndMove()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w"), other = s.addWorkspace("o");
        const QString a = s.addSession(ws, "a", {}), b = s.addSession(ws, "b", {}), c = s.addSession(ws, "c", {});
        QCOMPARE(call(s, t, "session.move", a, {{"targets", QJsonArray{a, b}}, {"workspace", other}})["result"]["affected"].toInt(), 2);
        QCOMPARE(s.workspace(other)->sessions.size(), 2);
        const QJsonObject r = call(s, t, "session.close", a, {{"targets", QJsonArray{a, c}}})["result"].toObject();
        QCOMPARE(r["affected"].toInt(), 2);
        QVERIFY(!s.session(a) && !s.session(c) && s.session(b));
        QCOMPARE(call(s, t, "session.close", b, {{"targets", QJsonArray{}}})["error"].toString(), QStringLiteral("session.close requires at least one --target"));
    }

    void messagesBetweenPanes()
    {
        Store s;
        FakeTerminals t;
        const QString ws = s.addWorkspace("w");
        const QString a = s.addSession(ws, "a", {}), b = s.addSession(ws, "b", {});
        const QString pa = QUuid::createUuid().toString(QUuid::WithoutBraces), pb = QUuid::createUuid().toString(QUuid::WithoutBraces);
        t.panes = {{a, {pa}}, {b, {pb}}};
        const QString me = a + ":" + pa;
        QCOMPARE(call(s, t, "msg.send", {}, {{"body", "hi"}})["error"].toString(), QStringLiteral("msg.send requires --to or --all"));
        QCOMPARE(call(s, t, "msg.send", {}, {{"body", "hi"}, {"identity", a + ":left"}, {"all", true}})["error"].toString(),
                 QStringLiteral("identity \"%1:left\" must name a pane id, not a role").arg(a));
        QJsonObject r = call(s, t, "msg.send", {}, {{"body", "hi"}, {"identity", me}, {"recipients", QJsonArray{b + ":left", a + ":right"}}})["result"].toObject();
        QCOMPARE(r["delivered"].toArray(), QJsonArray{b + ":" + pb});
        QCOMPARE(r["rejected"][0]["reason"].toString(), QStringLiteral("unknown pane"));
        QCOMPARE(t.events.last()["kind"].toString(), QStringLiteral("message"));
        QVERIFY(call(s, t, "msg.send", {}, {{"body", "all"}, {"identity", me}, {"all", true}})["ok"].toBool()); // not to the sender
        QCOMPARE(call(s, t, "msg.read", {}, {{"identity", me}})["result"]["messages"].toArray().size(), 0);
        const QJsonObject inbox = call(s, t, "msg.read", {}, {{"identity", b + ":" + pb}})["result"].toObject();
        QCOMPARE(inbox["messages"].toArray().size(), 2);
        QCOMPARE(inbox["messages"][0]["from"].toString(), me);
        QCOMPARE(inbox["messages"][0]["body"].toString(), QStringLiteral("hi"));
        QCOMPARE(call(s, t, "msg.ack", {}, {{"identity", b + ":" + pb}, {"ids", QJsonArray{inbox["messages"][0]["id"]}}})["result"]["acked"].toArray().size(), 1);
        const QJsonObject rest = call(s, t, "msg.read", {}, {{"identity", b + ":" + pb}, {"ack", true}})["result"].toObject();
        QCOMPARE(rest["acked"].toArray().size(), 1);
        QCOMPARE(call(s, t, "msg.read", {}, {{"identity", b + ":" + pb}})["result"]["messages"].toArray().size(), 0);
        QCOMPARE(call(s, t, "msg.read")["error"].toString(), QStringLiteral("msg.read requires an identity: --as SESSION:PANE-ID"));
    }

    void absentFeaturesAndArgumentRules()
    {
        Store s;
        FakeTerminals t;
        const QString id = call(s, t, "session.new")["result"]["id"].toString();
        for (const char *cmd : {"zmx.list", "browser.links", "quick.type", "session.scratch", "session.background", "surface.cursor", "config.reload", "session.restart"})
            QVERIFY2(call(s, t, cmd, id)["error"].toString().startsWith(QLatin1String(cmd) + QStringLiteral(" is not supported on this platform (")), cmd);
        QVERIFY(call(s, t, "no.such")["error"].toString().startsWith(QStringLiteral("unknown command")));
        QCOMPARE(pickArgsError({}), QStringLiteral("pick.open requires items"));
        QCOMPARE(pickArgsError({{"items", QJsonArray{QJsonObject{{"id", "a"}, {"label", "A"}}, QJsonObject{{"id", "a"}, {"label", "B"}}}}}),
                 QStringLiteral("pick item ids must be unique"));
        QCOMPARE(pickArgsError({{"items", QJsonArray{QJsonObject{{"id", "a"}, {"label", "A"}}}}, {"selection", "z"}}), QStringLiteral("pick select must name an item id"));
        QJsonObject ask{{"title", "Name?"}, {"input", "line"}};
        QCOMPARE(askArgsError(&ask), QString());
        QCOMPARE(ask["buttons"].toArray().size(), 2); // a form gets OK / Cancel
        QJsonObject bad{{"title", "x"}, {"buttons", QJsonArray{QJsonObject{{"id", "y"}, {"label", "Y"}, {"hotkey", "yy"}}}}};
        QCOMPARE(askArgsError(&bad), QStringLiteral("ask button hotkey must be one ASCII letter"));
        QJsonObject none{{"title", "x"}};
        QCOMPARE(askArgsError(&none), QStringLiteral("ask.open requires buttons"));
        QCOMPARE(call(s, t, "ask.open", id, {{"title", ""}})["error"].toString(), QStringLiteral("ask.open requires a title"));
        QVERIFY(call(s, t, "ask.open", id, ask)["ok"].toBool());
        QCOMPARE(t.appCmd, QStringLiteral("ask.open"));
        QCOMPARE(call(s, t, "pick.result")["error"].toString(), QStringLiteral("pick.result requires a pick id"));
        QCOMPARE(call(s, t, "session.search", id, {{"to", "up"}})["error"].toString(), QStringLiteral("session.search --to must be next|prev|close"));
    }
};

QTEST_GUILESS_MAIN(TestCore)
#include "test_core.moc"
