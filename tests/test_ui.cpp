#include "mainwindow.h"
#include "sidebar.h"
#include "store.h"

#include <QApplication>
#include <QLineEdit>
#include <QMenu>
#include <QTimer>
#include <QPointer>
#include <QTemporaryDir>
#include <QToolButton>
#include <QTest>

class TestUi : public QObject
{
    Q_OBJECT

    QTemporaryDir dir;

private Q_SLOTS:
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
