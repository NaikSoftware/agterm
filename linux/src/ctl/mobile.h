#pragma once

#include <QHash>
#include <QString>

// elisctl mobile serve|reset; socketPath is the app's control socket the relay forwards to
int mobileCommand(const QString &sub, const QString &socketPath, const QHash<QString, QString> &opt);
