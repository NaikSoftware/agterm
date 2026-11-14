#pragma once

#include "installers.h"

class QMenu;

QString bundled(const QString &name); // agent-status | skill/agterm; "" when not shipped
Install::Report runInstaller(const QString &which, const QString &home); // agent-hooks | cli | skill under home, unattended
QByteArray extrasFingerprint(); // changes with the shipped hooks and skill and with the binary's path
QString extrasStamp();          // the fingerprint of the last unattended install of all three
// an installed build whose fingerprint differs from the stamp (first launch, update, moved prefix) runs
// `agterm-qt --install all` in the background, logging to extras-install.log in the state dir
void installExtrasOnUpdate();
void addHelpMenu(QMenu *help); // Developer Documentation…
