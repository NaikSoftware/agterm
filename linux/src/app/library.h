#pragma once

#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>

class MainWindow;
class Store;

// The window library: named windows, each its own workspace tree in <state>/windows/<id>.json, indexed by
// <state>/windows.json. Routes control requests to the addressed window and owns the window.* commands.
class WindowLibrary : public QObject
{
    Q_OBJECT
public:
    struct Entry {
        QString id, name;
        bool open = false;
        Store *store = nullptr;
        MainWindow *window = nullptr;
    };

    explicit WindowLibrary(const QString &stateDir);
    ~WindowLibrary() override;
    void load(); // opens the windows open at the last quit; a lone workspaces.json becomes window 1
    QJsonObject dispatch(const QJsonObject &request);
    const QList<Entry> &entries() const { return m_entries; }
    QList<MainWindow *> openWindows() const;
    MainWindow *active() const;
    QString newWindow(const QString &name, bool minimized = false);
    bool select(const QString &id); // raise an open window, or open a closed one
    void close(const QString &id);  // the bundle stays, reopenable
    bool remove(const QString &id, QString *error);
    void rename(const QString &id, const QString &name);
    bool go(int step, QString *error); // over open windows, wrapping
    void quit();
    bool quitting() const { return m_quitting; }
    // from MainWindow::closeEvent; only a user's close or window.close keeps a bundle closed: Qt's quit closes every window too
    void windowClosed(MainWindow *window, bool byUser);
    bool saveIndex();

Q_SIGNALS:
    void changed();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    Entry *entry(const QString &id);
    Entry *entryOf(const MainWindow *window);
    QString resolve(const QString &selector, QString *error);
    void attach(Entry &e, bool minimized = false);
    void syncSettings(Store *from);
    QJsonObject windowCommand(const QString &cmd, const QString &target, const QJsonObject &args);
    QString path(const QString &id) const;
    QString m_dir;
    QList<Entry> m_entries;
    QPointer<MainWindow> m_active;
    bool m_quitting = false;
    QString m_closing; // the window window.close is closing
};
