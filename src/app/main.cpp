#include "control.h"
#include "help.h"
#include "hooks.h"
#include "library.h"
#include "livehost.h"
#include "mainwindow.h"
#include "paths.h"
#include "smoothwheel.h"
#include "store.h"

#include <KConfig>
#include <KConfigGroup>
#include <KSharedConfig>
#include <QApplication>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QIcon>
#include <QJsonDocument>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QMessageBox>
#include <QSocketNotifier>
#include <QTimer>

#include <csignal>
#include <sys/socket.h>
#include <unistd.h>

// One request line in, one response line out, then the connection closes.
static void serve(QLocalServer &server, WindowLibrary &library)
{
    QObject::connect(&server, &QLocalServer::newConnection, &server, [&] {
        while (QLocalSocket *socket = server.nextPendingConnection()) {
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket, &library] {
                if (!socket->canReadLine()) {
                    if (socket->bytesAvailable() > maxRequestBytes)
                        socket->abort();
                    return;
                }
                QJsonParseError err{};
                const auto doc = QJsonDocument::fromJson(socket->readLine(maxRequestBytes + 1), &err);
                const QJsonObject response = doc.isObject() ? library.dispatch(doc.object())
                                                            : QJsonObject{{"ok", false}, {"error", QStringLiteral("bad request: %1").arg(err.errorString())}};
                socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact) + '\n');
                socket->disconnectFromServer();
            });
        }
    });
}

// A roomier default profile for this app only; KonsolePart hosts keep their own DefaultProfile, so Konsole is untouched
// and a profile the user picks later in Settings wins.
static void ensureProfile()
{
    KConfigGroup entry = KSharedConfig::openConfig()->group(QStringLiteral("Desktop Entry"));
    if (!entry.readEntry("DefaultProfile", QString()).isEmpty())
        return;
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/konsole");
    const QString file = dir + QStringLiteral("/agterm-qt.profile");
    if (!QFile::exists(file)) {
        QDir().mkpath(dir);
        KConfig profile(file, KConfig::SimpleConfig);
        profile.group(QStringLiteral("General")).writeEntry("Name", "agterm-qt");
        profile.group(QStringLiteral("General")).writeEntry("Parent", "FALLBACK/");
        profile.group(QStringLiteral("General")).writeEntry("TerminalMargin", 10);
        profile.group(QStringLiteral("Appearance")).writeEntry("ColorScheme", "Breeze");
        profile.sync();
    }
    entry.writeEntry("DefaultProfile", "agterm-qt.profile");
    entry.sync();
}

// agterm-qt --install agent-hooks|cli|skill [--home DIR]: the Help menu's installers without a window
static int installFromCommandLine(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments();
    const qsizetype at = args.indexOf(QStringLiteral("--home"));
    const QString home = at > 0 && at + 1 < args.size() ? args[at + 1] : QDir::homePath();
    const Install::Report r = runInstaller(args.value(2), home, nullptr);
    if (!r.error.isEmpty())
        return fprintf(stderr, "Install Failed: %s\n", qPrintable(r.error)), 1;
    printf("%s\n%s\n", qPrintable(r.title), qPrintable(r.text()));
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && qstrcmp(argv[1], "--install") == 0)
        return installFromCommandLine(argc, argv);
    QApplication app(argc, argv);
    app.installEventFilter(new SmoothWheel(&app));
    app.setApplicationName(QStringLiteral("agterm-qt")); // also names the Konsole-part profile namespace
    app.setApplicationVersion(QLatin1String(appVersion));
    app.setDesktopFileName(QStringLiteral("agterm-qt"));
    Q_INIT_RESOURCE(resources); // before the window: the fallback icon lives in the static UI library
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("agterm-qt"), QIcon(QStringLiteral(":/agterm-qt.png"))));

    const QString dir = stateDir();
    QDir().mkpath(dir);
    // two instances on one state dir would each rewrite the whole file from memory and lose the other's sessions
    QLockFile lock(dir + QStringLiteral("/agterm.lock"));
    if (!lock.tryLock(0)) {
        QMessageBox::warning(nullptr, QStringLiteral("agterm-qt"), QStringLiteral("agterm-qt is already running on %1").arg(dir));
        return 1;
    }

    ensureProfile();
    const bool firstLaunch = !Install::hasPriorState(dir); // read before the library writes anything there
    WindowLibrary library(dir);
    library.load(); // the windows open at the last quit, each with its saved frame
    MainWindow &window = *library.active();
    // Fresh shells and Re-run launches end every daemon a live run left, as master's reap; a live one has reattached
    for (const auto &e : library.entries())
        if (e.store) { // a window closed at the last quit has no store loaded
            if (e.store->restoreModeAtLaunch != QLatin1String("live"))
                for (const QString &live : Live::sockets(dir))
                    Live::kill(live);
            break;
        }

    QLocalServer server;
    QLocalServer::removeServer(socketPath()); // safe: the lock says no live instance owns it
    server.setSocketOptions(QLocalServer::UserAccessOption);
    const bool listening = server.listen(socketPath());
    if (!listening)
        qWarning("control socket %s: %s", qPrintable(socketPath()), qPrintable(server.errorString()));
    for (MainWindow *w : library.openWindows())
        w->setSocketStatus(listening, server.errorString());
    serve(server, library);
    window.events()->emitEvent(QStringLiteral("app.launched")); // hooks loaded, socket accepting, sessions restored

    // SIGTERM (logout, kill) must save like a window close; a self-pipe moves it onto the event loop
    static int sigFd[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sigFd) == 0) {
        auto *notifier = new QSocketNotifier(sigFd[1], QSocketNotifier::Read, &app);
        QObject::connect(notifier, &QSocketNotifier::activated, &app, &QCoreApplication::quit);
        for (int sig : {SIGTERM, SIGINT, SIGHUP})
            std::signal(sig, [](int) { [[maybe_unused]] auto n = ::write(sigFd[0], "x", 1); });
    }
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &library, [&library] {
        for (MainWindow *w : library.openWindows())
            w->save();
        library.saveIndex();
    });
    if (firstLaunch) // after the socket binds: the dialog is window-modal, never in the request path
        QTimer::singleShot(0, &window, [&window] { showWelcome(&window); });
    if (const QString shot = qEnvironmentVariable("AGTERM_SCREENSHOT"); !shot.isEmpty()) // dev aid for UI review
        QTimer::singleShot(6000, &window, [&window, shot] { window.grab().save(shot); });

    return app.exec();
}
