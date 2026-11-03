#include "mainwindow.h"
#include "store.h"

#include <QApplication>
#include <QTemporaryDir>
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

        QTest::keyClick(term, Qt::Key_T, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.allSessions().size(), 2);

        const QString first = store.workspaces.first().sessions.first().id;
        store.setStatus(first, "blocked");
        QTest::keyClick(&w, Qt::Key_PageUp, Qt::ControlModifier);
        QTRY_COMPARE(store.selected, first);
        QCOMPARE(store.session(first)->status, QStringLiteral("blocked")); // a shortcut is not engagement

        QTRY_COMPARE(QApplication::focusWidget(), term); // focus follows the selection back to its terminal
        QTest::keyClick(term, Qt::Key_A);
        QCOMPARE(store.session(first)->status, QStringLiteral("idle"));
    }
};

QTEST_MAIN(TestUi)
#include "test_ui.moc"
