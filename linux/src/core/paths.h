#pragma once

#include <QStandardPaths>
#include <QString>

// Shared by the app and elisctl so both derive the same socket: --socket, then ELIS_STATE_DIR, then default.
inline QString stateDir()
{
    const QString env = qEnvironmentVariable("ELIS_STATE_DIR");
    return env.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/elis") : env;
}

inline QString socketPath()
{
    return stateDir() + QStringLiteral("/elis.sock");
}

inline constexpr int maxRequestBytes = 4 << 20;
inline constexpr const char *appVersion = "0.1.0";
