#include "livehost.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <csignal>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace Live {

QString dir(const QString &stateDir)
{
    QString base = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (base.isEmpty())
        base = QDir::tempPath();
    const QByteArray hash = QCryptographicHash::hash(QDir::cleanPath(stateDir).toUtf8(), QCryptographicHash::Sha1).toHex().left(8);
    return base + QStringLiteral("/agterm-qt-") + QString::fromLatin1(hash);
}

QString socket(const QString &stateDir, const QString &sessionId, const QString &pane)
{
    return dir(stateDir) + QLatin1Char('/') + sessionId + QLatin1Char('.') + pane;
}

void makeDir(const QString &stateDir)
{
    if (const QString d = dir(stateDir); QDir().mkpath(d))
        QFile::setPermissions(d, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
}

int shellPid(const QString &socket)
{
    QFile f(socket + QStringLiteral(".pid"));
    bool ok = false;
    const int pid = f.open(QIODevice::ReadOnly) ? f.readAll().trimmed().toInt(&ok) : -1;
    return ok && pid > 0 ? pid : -1;
}

int foregroundPid(int shellPid)
{
    QFile f(QStringLiteral("/proc/%1/stat").arg(shellPid));
    if (shellPid <= 0 || !f.open(QIODevice::ReadOnly))
        return -1;
    const QByteArray line = f.readAll();
    const QList<QByteArray> fields = line.mid(line.lastIndexOf(')') + 2).split(' '); // state ppid pgrp session tty tpgid
    const int tpgid = fields.size() > 5 ? fields[5].toInt() : -1;
    return tpgid > 0 ? tpgid : shellPid;
}

bool alive(const QString &socket)
{
    const int pid = shellPid(socket);
    return pid > 0 && QFile::exists(socket) && ::kill(pid, 0) == 0;
}

QString paneId(const QString &socket)
{
    QFile f(socket + QStringLiteral(".id"));
    return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()).trimmed() : QString();
}

void setPaneId(const QString &socket, const QString &id)
{
    if (QFile f(socket + QStringLiteral(".id")); f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(id.toUtf8());
}

void kill(const QString &socket)
{
    const QByteArray path = QFile::encodeName(socket);
    sockaddr_un a{};
    a.sun_family = AF_UNIX;
    std::strncpy(a.sun_path, path.constData(), sizeof a.sun_path - 1);
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd >= 0 && ::connect(fd, reinterpret_cast<const sockaddr *>(&a), sizeof a) == 0) {
        const char frame[5] = {'k', 0, 0, 0, 0};
        if (::write(fd, frame, sizeof frame) == sizeof frame) {
            char sink[4096];
            pollfd p{fd, POLLIN, 0};
            while (::poll(&p, 1, 2000) > 0 && ::read(fd, sink, sizeof sink) > 0) {
            } // EOF once the daemon is done
        }
    }
    if (fd >= 0)
        ::close(fd);
    for (const char *suffix : {"", ".pid", ".id"})
        QFile::remove(socket + QLatin1String(suffix));
    QDir().rmdir(QFileInfo(socket).path()); // the last daemon takes the dir with it
}

void move(const QString &from, const QString &to)
{
    for (const char *suffix : {"", ".pid", ".id"}) {
        QFile::remove(to + QLatin1String(suffix));
        QFile::rename(from + QLatin1String(suffix), to + QLatin1String(suffix)); // a bound socket is found by its path
    }
}

void swap(const QString &a, const QString &b)
{
    const QString tmp = a + QStringLiteral(".swap");
    move(a, tmp);
    move(b, a);
    move(tmp, b);
}

QStringList sockets(const QString &stateDir)
{
    QStringList out;
    const QDir d(dir(stateDir));
    for (const QString &name : d.entryList(QDir::System | QDir::Files))
        if (name.count(QLatin1Char('.')) == 1) // <session>.<pane>; the sidecars add a second suffix
            out << d.filePath(name);
    return out;
}

} // namespace Live
