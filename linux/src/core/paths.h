#pragma once

#include <QStandardPaths>
#include <QString>

// Shared by the app and agtermctl so both derive the same socket: --socket, then AGTERM_STATE_DIR, then default.
inline QString stateDir()
{
    const QString env = qEnvironmentVariable("AGTERM_STATE_DIR");
    return env.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/agterm-qt") : env;
}

inline QString socketPath()
{
    return stateDir() + QStringLiteral("/agterm.sock");
}

inline constexpr int maxRequestBytes = 4 << 20;
inline constexpr const char *appVersion = "0.1.0";
