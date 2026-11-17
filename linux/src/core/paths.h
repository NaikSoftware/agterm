#pragma once

#include <QStandardPaths>
#include <QString>

// Shared by the app and hangarctl so both derive the same socket: --socket, then HANGAR_STATE_DIR, then default.
inline QString stateDir()
{
    const QString env = qEnvironmentVariable("HANGAR_STATE_DIR");
    return env.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/hangar") : env;
}

inline QString socketPath()
{
    return stateDir() + QStringLiteral("/hangar.sock");
}

inline constexpr int maxRequestBytes = 4 << 20;
inline constexpr const char *appVersion = "0.1.0";
