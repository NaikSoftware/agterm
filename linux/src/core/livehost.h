#pragma once

#include <QString>
#include <QStringList>

// Live restore mode: each main/right pane runs under an agterm-session-host daemon that keeps its shell across app
// restarts (src/host/sessionhost.cpp owns the protocol). Daemons are named by session id and pane role.
namespace Live {
// $XDG_RUNTIME_DIR/agterm-qt-<hash of the state dir>: short enough for a unix socket path, gone after a reboot
QString dir(const QString &stateDir);
QString socket(const QString &stateDir, const QString &sessionId, const QString &pane);
void makeDir(const QString &stateDir); // owner-only, before a daemon binds in it
int shellPid(const QString &socket);          // the daemon's shell, from <socket>.pid; -1 before it is written
int foregroundPid(int shellPid);              // the shell's terminal foreground group (tpgid), the shell itself when idle
bool alive(const QString &socket);            // its shell is running; checked without attaching
QString paneId(const QString &socket);        // the AGTERM_PANE_ID the daemon's shell was started with
void setPaneId(const QString &socket, const QString &id);
void kill(const QString &socket);             // ends the daemon and its shell, synchronously
void move(const QString &from, const QString &to); // a pane changing role keeps its daemon
void swap(const QString &a, const QString &b);
QStringList sockets(const QString &stateDir); // every daemon socket in the dir
}
