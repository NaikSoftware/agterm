#include "mainwindow.h"
#include "hooks.h"
#include "sidebar.h"
#include "store.h"

#include <QApplication>
#include <QCheckBox>
#include <QDir>
#include <QFile>
#include <KPageDialog>
#include <QLineEdit>
#include <QMenu>
#include <QTimer>
#include <QPointer>
#include <QTemporaryDir>
#include <QToolButton>
#include <QSignalSpy>
#include <QJsonDocument>
#include <QJsonArray>
#include <QToolBar>
#include <QTest>

class TestUi : public QObject
{
    Q_OBJECT

    QTemporaryDir dir;

private Q_SLOTS:

    // the config dir follows AGTERM_STATE_DIR (set by ctest), so nothing here touches ~/.config
    static QString writeConfig(const QString &name, const QString &text)
    {
        const QString dir = qEnvironmentVariable("AGTERM_STATE_DIR") + QStringLiteral("/config");
        QDir().mkpath(dir);
        QFile f(dir + QLatin1Char('/') + name);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
            return {};
        f.write(text.toUtf8());
        return f.fileName();
    }

    static QWidget *display(MainWindow &)
    {
        const bool ok = QTest::qWaitFor([] { return QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"); }, 5000);
        return ok ? QApplication::focusWidget() : nullptr;
    }

    void keymapRebindsAndLeaderSequencesFireFromTheTerminal()
    {
        QTemporaryDir out;
        const QString touched = out.filePath("touched");
        writeConfig("keymap.conf", QStringLiteral("map ctrl+alt+l toggle_split\n"
                                                  "command \"Touch\" ctrl+a>g touch \"%1\" && echo \"{AGT_SESSION_ID}\" > \"%1\"\n"
                                                  "map bogus toggle_split\n")
                                       .arg(touched));
        Store store;
        MainWindow w(store, dir.filePath("keymap.json"));
        w.restore({});
        w.loadConfig();
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QCOMPARE(w.keymap().diagnostics.size(), 1);
        QCOMPARE(w.namedAction("toggle_split")->shortcut(), QKeySequence("Ctrl+Alt+L"));

        QTest::keyClick(term, Qt::Key_L, Qt::ControlModifier | Qt::AltModifier);
        QTRY_VERIFY(store.session(id)->hasSplit);
        QTest::keyClick(term, Qt::Key_D, Qt::ControlModifier | Qt::ShiftModifier); // its old chord is free now
        QVERIFY(store.session(id)->splitVisible);

        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"), 5000);
        term = QApplication::focusWidget();
        QTest::keyClick(term, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClick(term, Qt::Key_G);
        QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(touched) && QFile(touched).size() > 0, 5000);
        QFile f(touched);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll().trimmed(), id.toUtf8()); // {AGT_SESSION_ID} expanded

        QString error;
        QJsonObject result;
        QVERIFY(!w.appCommand("keymap.run", id, {{"name", "nope"}}, &result, &error));
        QVERIFY(w.appCommand("keymap.list", {}, {}, &result, &error));
        QVERIFY(QJsonDocument(result).toJson().contains("\"marked\": true"));
    }

    void themePickerPreviewsRevertsAndCommits()
    {
        Store store;
        MainWindow w(store, dir.filePath("theme.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QVERIFY(w.themes().contains("DarkPastels"));
        const QColor before = term->palette().color(QPalette::Window);
        w.previewTheme("DarkPastels");
        QTRY_VERIFY(term->palette().color(QPalette::Window) != before);
        w.previewTheme({});
        QTRY_COMPARE(term->palette().color(QPalette::Window), before);

        w.selectTheme();
        auto *search = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        QVERIFY(search);
        QTest::keyClicks(search, "DarkPastels");
        QTRY_VERIFY(term->palette().color(QPalette::Window) != before); // the filtered row is previewed
        QTest::keyClick(search, Qt::Key_Escape);
        QTRY_COMPARE(term->palette().color(QPalette::Window), before);
        QVERIFY(store.settings.theme.isEmpty());

        w.selectTheme();
        search = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        QTest::keyClicks(search, "DarkPastels");
        QTest::keyClick(search, Qt::Key_Return);
        QCOMPARE(store.settings.theme, QStringLiteral("DarkPastels"));
        QString error;
        QJsonObject result;
        QVERIFY(!w.appCommand("theme.set", {}, {{"name", "NoSuchScheme"}}, &result, &error));
        QVERIFY(w.appCommand("theme.set", {}, {}, &result, &error));
        QTRY_COMPARE(term->palette().color(QPalette::Window), before); // back to the profile's scheme
    }

    void oscNotificationsRaiseTheBadge()
    {
        Store store;
        MainWindow w(store, dir.filePath("osc.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString front = store.addSession(ws, {}, {}), back = store.addSession(ws, {}, {});
        store.select(front);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        display(w);
        QSignalSpy notified(&store, &Store::notified);
        QString error;
        QTest::qWait(500); // the shell is up
        w.type(back, QStringLiteral("printf '\\033]9;nine\\007'; printf '\\033]777;notify;Title;Body\\007'\n"), &error);
        QTRY_COMPARE_WITH_TIMEOUT(notified.size(), 2, 5000);
        QStringList got;
        for (const auto &n : notified)
            got << n[1].toString() + "|" + n[2].toString();
        got.sort();
        QCOMPARE(got, (QStringList{"Title|Body", "|nine"}));
        QCOMPARE(store.session(back)->unseen, 2);
    }

    void settingsDialogAppliesLive()
    {
        Store store;
        MainWindow w(store, dir.filePath("settings.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QAction *split = nullptr;
        for (QAction *a : w.findChild<QToolBar *>("titleStrip")->actions())
            if (a->text() == QStringLiteral("Split"))
                split = a;
        QVERIFY(split && split->isVisible());
        w.showSettings();
        auto *dlg = w.findChild<KPageDialog *>("settingsDialog");
        QVERIFY(dlg);
        QCheckBox *box = nullptr;
        for (QWidget *x : QApplication::allWidgets()) // KPageView parents a page only once it is shown
            if (auto *b = qobject_cast<QCheckBox *>(x); b && b->text().remove('&') == QStringLiteral("Split view")) // KDE adds accelerators
                box = b;
        QVERIFY(box);
        QVERIFY(box->isChecked());
        box->setChecked(false);
        QVERIFY(!store.settings.shows("split"));
        QVERIFY(!split->isVisible());
        const double size = term->font().pointSizeF();
        Settings s = store.settings;
        s.fontSize = size + 4;
        store.setSettings(s);
        QTRY_COMPARE(term->font().pointSizeF(), size + 4);
        QString error;
        QVERIFY(w.font(store.selected, "main", "reset", &error)); // reset returns to the Settings size, not the profile's
        QCOMPARE(term->font().pointSizeF(), size + 4);
        dlg->close();
    }
    void shortcutsReachTheAppFromTheTerminalAndTypingClearsAttention()
    {
        Store store;
        MainWindow w(store, dir.filePath("state.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QWidget *term = QApplication::focusWidget();

        QTest::keyClick(term, Qt::Key_N, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.allSessions().size(), 2);

        const QString first = store.workspaces.first().sessions.first().id;
        store.setStatus(first, "blocked");
        QTest::keyClick(term, Qt::Key_Up, Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, first);
        QCOMPARE(store.session(first)->status, QStringLiteral("blocked")); // a shortcut is not engagement

        QTRY_COMPARE(QApplication::focusWidget(), term); // focus follows the selection back to its terminal
        QTest::keyClick(term, Qt::Key_A);
        QCOMPARE(store.session(first)->status, QStringLiteral("idle"));
    }

    void undoCloseBringsBackTheSameTerminal()
    {
        Store store;
        MainWindow w(store, dir.filePath("undo.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        store.select(a);
        store.select(store.addSession(ws, {}, {}));
        const QString closing = store.selected;
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QPointer<QWidget> term = QApplication::focusWidget();
        QTest::keyClick(term, Qt::Key_W, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, a);
        QVERIFY(!store.session(closing));
        QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != term);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, closing);
        QVERIFY(term); // the shell survived the grace window
        QTRY_COMPARE(QApplication::focusWidget(), term.data());
    }

    void overlayRunsOverTheSessionAndReportsItsExitStatus()
    {
        Store store;
        MainWindow w(store, dir.filePath("overlay.json"));
        w.restore({});
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QVERIFY(term);
        auto run = [&](const QString &cmd, const QJsonObject &args = {}) {
            QJsonObject result;
            QString error;
            const bool ok = w.appCommand(cmd, id, args, &result, &error);
            return ok ? result : QJsonObject{{"error", error}};
        };
        QVERIFY(!run("session.overlay.open", {{"command", "sleep 30; exit 3"}, {"sizePercent", 50}}).contains("error"));
        QCOMPARE(run("session.overlay.open", {{"command", "true"}})["error"].toString(), QStringLiteral("overlay already open"));
        QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != term); // the cover owns the keyboard
        QCOMPARE(w.sessionExtras(id)["overlaySizePercent"].toInt(), 50);
        QCOMPARE(run("session.overlay.result")["error"].toString(), QStringLiteral("overlay still running"));
        QCOMPARE(run("session.overlay.toggle")["text"].toString(), QStringLiteral("hidden"));
        QCOMPARE(w.sessionExtras(id)["hiddenOverlays"].toArray().first().toString(), QStringLiteral("session"));
        QTRY_COMPARE(QApplication::focusWidget(), term);
        QCOMPARE(w.namedAction("toggle_overlay")->text(), QStringLiteral("Show Overlays"));
        QVERIFY(!run("session.overlay.close").contains("error"));
        QVERIFY(!w.sessionExtras(id)["overlay"].toBool());

        QVERIFY(!run("session.overlay.open", {{"command", "exit 3"}}).contains("error"));
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id)["overlay"].toBool(), 5000);
        QCOMPARE(run("session.overlay.result")["exitCode"].toInt(), 3);
        QTRY_COMPARE(QApplication::focusWidget(), term);

        // the HUD takes no input: typing still reaches the terminal under it
        QVERIFY(!run("session.hud.open", {{"message", "building"}, {"spinner", "dot"}, {"hideAfter", 1}}).contains("error"));
        QCOMPARE(w.sessionExtras(id)["hud"].toObject()["message"].toString(), QStringLiteral("building"));
        QCOMPARE(QApplication::focusWidget(), term);
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id).contains("hud"), 3000); // --hide-after clears it
        QCOMPARE(run("session.hud.close")["error"].toString(), QStringLiteral("no hud"));

        qputenv("VISUAL", "sleep 1; true"); // Edit Keymap runs the editor in a 95% overlay and closes with it
        w.namedAction("edit_keymap")->trigger();
        QCOMPARE(w.sessionExtras(id)["overlaySizePercent"].toInt(), 95);
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id)["overlay"].toBool(), 5000);
        qunsetenv("VISUAL");
    }

    void dashboardHostsTheLivePanesAndGivesThemBack()
    {
        Store store;
        MainWindow w(store, dir.filePath("dash.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        const QString b = store.addSession(ws, {}, {});
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *termA = display(w);
        QVERIFY(termA);
        QJsonObject result;
        QString error;
        QVERIFY2(w.appCommand("dashboard", {}, {{"cells", QJsonArray{a + ":left", b + ":left"}}, {"fontMode", "untouched"}}, &result, &error), qPrintable(error));
        QCOMPARE(w.chromeState()["dashboardMembers"].toArray().size(), 2);
        QWidget *grid = QApplication::focusWidget();
        QVERIFY(grid && grid->isAncestorOf(termA)); // the live terminal, not a copy
        QCOMPARE(w.windowTitle(), QStringLiteral("Dashboard"));
        QTest::keyClick(grid, Qt::Key_Right);
        QCOMPARE(w.chromeState()["dashboardHighlighted"].toString(), b + ":left");
        QTest::keyClick(grid, Qt::Key_Right); // no wrap
        QCOMPARE(w.chromeState()["dashboardHighlighted"].toString(), b + ":left");
        QTest::keyClick(grid, Qt::Key_X); // typing goes nowhere
        QTest::keyClick(grid, Qt::Key_Return);
        QCOMPARE(store.selected, b);
        QVERIFY(!w.chromeState().contains("dashboardMembers"));
        for (QWidget *up = termA; up; up = up->parentWidget())
            QVERIFY(up->objectName() != QLatin1String("dashCell")); // back in its own splitter

        w.namedAction("dashboard")->trigger(); // the MRU grid with auto-size
        QCOMPARE(w.chromeState()["dashboardFontMode"].toString(), QStringLiteral("auto"));
        store.removeSession(a); // a member that goes away leaves the grid to the survivors
        QTRY_COMPARE(w.chromeState()["dashboardMembers"].toArray(), (QJsonArray{b + ":left"}));
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Escape);
        QVERIFY(!w.chromeState().contains("dashboardMembers"));
    }

    void selectingASessionUpdatesTheSidebarInPlace()
    {
        Store store;
        MainWindow w(store, dir.filePath("inplace.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {}), b = store.addSession(ws, {}, {});
        store.select(a);
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QTreeWidgetItem *wsItem = tree->topLevelItem(0), *rowA = wsItem->child(0), *rowB = wsItem->child(1);
        store.select(b);
        store.setStatus(a, "blocked");
        QCOMPARE(tree->topLevelItem(0), wsItem);
        QCOMPARE(wsItem->child(0), rowA);
        QCOMPARE(wsItem->child(1), rowB);
        QVERIFY(rowB->isSelected() && !rowA->isSelected());
        QCOMPARE(rowA->data(0, SidebarRole::Status).toString(), QStringLiteral("blocked"));
        store.addSession(ws, {}, {}); // a new row is a structural change
        QCOMPARE(tree->topLevelItem(0)->childCount(), 3);
    }

    void fontKeysZoomTheTerminalAndARelaunchKeepsIt()
    {
        QJsonObject saved;
        double base = 0;
        {
            Store store;
            MainWindow w(store, dir.filePath("font.json"));
            w.restore({});
            store.select(store.addSession(store.addWorkspace("w"), {}, {}));
            w.show();
            w.activateWindow();
            QVERIFY(QTest::qWaitForWindowActive(&w));
            QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"), 5000);
            QWidget *term = QApplication::focusWidget();
            base = term->font().pointSizeF();
            QTest::keyClick(term, Qt::Key_Plus, Qt::ControlModifier | Qt::ShiftModifier);
            QTest::keyClick(term, Qt::Key_Plus, Qt::ControlModifier | Qt::ShiftModifier);
            QCOMPARE(term->font().pointSizeF(), base + 2);
            QCOMPARE(store.session(store.selected)->fontSize, base + 2);
            QTest::keyClick(term, Qt::Key_0, Qt::ControlModifier | Qt::ShiftModifier);
            QCOMPARE(term->font().pointSizeF(), base);
            QCOMPARE(store.session(store.selected)->fontSize, 0.0);
            QString e;
            QVERIFY(w.font(store.selected, "main", "dec", &e));
            QCOMPARE(store.session(store.selected)->fontSize, base - 1);
            saved = store.toJson();
        }
        Store store;
        store.fromJson(saved);
        MainWindow w(store, dir.filePath("font2.json"));
        w.restore({});
        w.show();
        QWidget *term = nullptr;
        for (QWidget *x : w.findChildren<QWidget *>())
            if (x->inherits("Konsole::TerminalDisplay"))
                term = x;
        QVERIFY(term);
        QCOMPARE(term->font().pointSizeF(), base - 1);
    }

    void recentButtonListsTheOtherRecentSessions()
    {
        Store store;
        MainWindow w(store, dir.filePath("recent.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "alpha", {}), b = store.addSession(ws, "beta", {});
        store.select(a);
        w.show();
        QToolButton *clock = nullptr;
        for (auto *t : w.findChildren<QToolButton *>())
            if (t->defaultAction() && t->defaultAction()->text().startsWith(QLatin1String("Recent sessions")))
                clock = t;
        QVERIFY(clock && !clock->isEnabled()); // nowhere else to go yet
        store.select(b);
        QVERIFY(clock->isEnabled());
        QStringList listed;
        QTimer::singleShot(0, this, [&] {
            auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget());
            QVERIFY(menu);
            for (QAction *x : menu->actions())
                listed << x->text();
            menu->actions().first()->trigger();
            menu->close();
        });
        clock->click();
        QTRY_COMPARE(listed, QStringList{QStringLiteral("alpha\tw")});
        QCOMPARE(store.selected, a);
    }

    void footerFilterNarrowsTheTreeAndTintReachesTheRow()
    {
        Store store;
        MainWindow w(store, dir.filePath("filter.json"));
        w.restore({});
        const QString a = store.addWorkspace("a");
        store.addWorkspace("b");
        store.select(store.addSession(a, {}, {}));
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QToolButton *filter = nullptr;
        for (auto *b : w.findChildren<QToolButton *>())
            if (b->accessibleName() == QLatin1String("Toggle Workspace Filter"))
                filter = b;
        QVERIFY(filter && !filter->isEnabled());
        QCOMPARE(tree->topLevelItemCount(), 2);
        store.focusWorkspace(a, "add");
        QVERIFY(filter->isEnabled());
        QCOMPARE(tree->topLevelItemCount(), 2);
        filter->click();
        QVERIFY(store.focusEnabled);
        QCOMPARE(tree->topLevelItemCount(), 1);
        QVERIFY(tree->topLevelItem(0)->data(0, SidebarRole::Focused).toBool());
        store.setTint(a, "red");
        QCOMPARE(tree->topLevelItem(0)->data(0, SidebarRole::TintColor).toString(), QStringLiteral("red"));
    }

    void sessionPaletteFiltersAndSelects()
    {
        Store store;
        MainWindow w(store, dir.filePath("palette.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, "alpha", {}));
        const QString beta = store.addSession(ws, "beta", {});
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_P, Qt::ControlModifier);
        QTRY_VERIFY(qobject_cast<QLineEdit *>(QApplication::focusWidget()));
        QTest::keyClicks(QApplication::focusWidget(), "bet");
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Return);
        QCOMPARE(store.selected, beta);
    }
};

QTEST_MAIN(TestUi)
#include "test_ui.moc"
