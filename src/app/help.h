#pragma once

#include "installers.h"

class QMenu;
class QWidget;

QString bundled(const QString &name); // agent-status | skill/agterm; "" when not shipped
// agent-hooks | cli | skill under home; parent null runs without asking (agterm-qt --install)
Install::Report runInstaller(const QString &which, const QString &home, QWidget *parent);
void showReport(QWidget *parent, const Install::Report &report);
void addHelpMenu(QMenu *help, QWidget *window); // Developer Documentation…, then the three installers
void showWelcome(QWidget *window);              // master's FirstRunWelcome dialog
