// The agent extras (hangarctl link, agent status hooks, agent skill), installed unattended whenever this installed
// build differs from the one that last installed them, and the Help menu.
#include "help.h"

#include "installers.h"
#include "paths.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QMenu>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>

// the shipped package: installed under share/hangar, or the source tree for a build-tree run
QString bundled(const QString &name)
{
    // next to the binary first, so a build-tree run never picks up an older installed copy from the data dirs
    QStringList candidates{QCoreApplication::applicationDirPath() + QStringLiteral("/../share/hangar/") + name};
#ifdef HANGAR_SOURCE_SHARE
    candidates << QStringLiteral(HANGAR_SOURCE_SHARE "/") + name;
#endif
    candidates << QStandardPaths::locate(QStandardPaths::GenericDataLocation, QStringLiteral("hangar/") + name, QStandardPaths::LocateDirectory);
    for (const QString &c : candidates)
        if (!c.isEmpty() && QFileInfo(c).isDir())
            return QFileInfo(c).canonicalFilePath();
    return {};
}

static QString hangarctl()
{
    return QCoreApplication::applicationDirPath() + QStringLiteral("/hangarctl");
}

// master's probe: the login shell says which OpenCode it runs and where v2 keeps its config
static Install::OpenCode probeOpenCode(const QString &home)
{
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("HANGAR_SESSION_ID"));
    env.insert(QStringLiteral("HOME"), home);
    // the login shell only sets up the environment; sh reads it, since fish rejects ${VAR-} (the user's shell may be fish)
    env.insert(QStringLiteral("HANGAR_OPENCODE_PROBE"), QStringLiteral("printf '\\nhangar-opencode-probe\\n%s\\n%s\\n' \"${OPENCODE_CONFIG_DIR-}\" \"${XDG_CONFIG_HOME:-$HOME/.config}\"; "
                                                                      "exec /usr/bin/env opencode --version"));
    p.setProcessEnvironment(env);
    p.start(qEnvironmentVariable("SHELL", QStringLiteral("/bin/sh")), {QStringLiteral("-ilc"), QStringLiteral("exec /bin/sh -c \"$HANGAR_OPENCODE_PROBE\"")});
    const bool ran = p.waitForFinished(3000);
    if (!ran)
        p.kill();
    QStringList out = QString::fromUtf8(p.readAllStandardOutput()).split(QLatin1Char('\n'));
    out = out.mid(out.lastIndexOf(QStringLiteral("hangar-opencode-probe")) + 1); // drops what rc files print first
    Install::OpenCode oc;
    const QString override = out.value(0).trimmed(), xdg = out.value(1).trimmed();
    oc.v2Dir = !override.isEmpty() ? QDir(home).absoluteFilePath(override) : xdg.isEmpty() ? QString() : xdg + QStringLiteral("/opencode");
    static const QRegularExpression version(QStringLiteral("^(?:opencode )?v?(\\d+)\\.\\d+\\.\\d+"));
    const auto m = version.match(out.mid(2).join(QLatin1Char('\n')).trimmed());
    const int major = m.hasMatch() ? m.captured(1).toInt() : 0;
    const bool legacy = QFileInfo(home + QStringLiteral("/.config/opencode")).isDir();
    if (major == 1 || major == 2)
        return oc.version = major, oc;
    if (!legacy && !QFileInfo(oc.v2Dir).isDir())
        return oc.version = -1, oc;
    return oc.version = 0, oc; // a version it cannot tell is skipped, not asked: the install runs unattended
}

Install::Report runInstaller(const QString &which, const QString &home)
{
    if (which == QLatin1String("agent-hooks"))
        return Install::agentHooks(home, bundled(QStringLiteral("agent-status")), hangarctl(), probeOpenCode(home));
    if (which == QLatin1String("cli"))
        return Install::commandLineTool(home, hangarctl());
    if (which == QLatin1String("skill"))
        return Install::skill(home, bundled(QStringLiteral("skill/hangar")));
    Install::Report r;
    r.error = QStringLiteral("unknown installer '%1' (agent-hooks, cli, skill, all)").arg(which);
    return r;
}

// what the extras were installed from and into: the shipped files, where this binary lives (the hooks bake its hangarctl
// path), and which agents exist, so an agent installed after hangar gets its hooks and skill on the next launch
QByteArray extrasFingerprint()
{
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(QCoreApplication::applicationFilePath().toUtf8());
    for (const char *agent : {"/.claude", "/.codex", "/.pi/agent", "/.config/opencode", "/.config/fish"})
        hash.addData(QFileInfo(QDir::homePath() + QLatin1String(agent)).isDir() ? "1" : "0");
    for (const QString &dir : {bundled(QStringLiteral("agent-status")), bundled(QStringLiteral("skill/hangar"))}) {
        QStringList files;
        for (QDirIterator it(dir, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories); it.hasNext();)
            files << it.next();
        files.sort(); // directory order is not stable
        for (const QString &f : std::as_const(files)) {
            QFile file(f);
            hash.addData(f.toUtf8());
            if (file.open(QIODevice::ReadOnly))
                hash.addData(file.readAll());
        }
    }
    return hash.result().toHex();
}

QString extrasStamp()
{
    return stateDir() + QStringLiteral("/extras-installed");
}

void installExtrasOnUpdate()
{
    // only an installed copy: a build-tree run must not repoint the user's hooks at a build that may go away
    if (!QFileInfo(QCoreApplication::applicationDirPath() + QStringLiteral("/../share/hangar")).isDir())
        return;
    QFile stamp(extrasStamp());
    if (stamp.open(QIODevice::ReadOnly) && stamp.readAll().trimmed() == extrasFingerprint())
        return;
    // a child process: the login-shell probe can take seconds, and the window must not wait for it
    QProcess p;
    p.setProgram(QCoreApplication::applicationFilePath());
    p.setArguments({QStringLiteral("--install"), QStringLiteral("all")});
    p.setStandardOutputFile(stateDir() + QStringLiteral("/extras-install.log"));
    p.setStandardErrorFile(stateDir() + QStringLiteral("/extras-install.log"), QIODevice::Append);
    if (!p.startDetached())
        qWarning("could not start the agent extras installer: %s", qPrintable(p.errorString()));
}

void addHelpMenu(QMenu *help)
{
    help->addAction(QObject::tr("Developer Documentation…"), help, [] { QDesktopServices::openUrl(QUrl(QStringLiteral("https://naiksoftware.github.io/hangar/docs#hangarctl"))); });
}
