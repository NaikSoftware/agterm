#pragma once

#include <QString>
#include <QStringList>

// Help ▸ Install … : master's installers, writing under an explicit home so tests and smoke run them in a temp dir.
namespace Install {

struct Report {
    QString title;
    QStringList lines;
    bool warning = false;
    QString error; // set: "Install Failed" with this as the body, nothing further written
    QString text() const { return lines.join(QLatin1Char('\n')); }
};

// OpenCode as the app found it: version 1 or 2, 0 = skip (the user chose), -1 = not found; v2Dir = its config dir
struct OpenCode {
    int version = -1;
    QString v2Dir;
};

// copies the shipped agent-status package to <home>/.config/agterm-qt/agent-status, bakes agtermctl's path into the
// wrappers, merges Claude Code hooks, sources the shell integration, and adds the Codex, Pi and OpenCode hooks
Report agentHooks(const QString &home, const QString &bundle, const QString &agtermctl, const OpenCode &openCode);
// links <home>/.local/bin/agtermctl to agtermctl; an agtermctl already there is left alone
Report commandLineTool(const QString &home, const QString &agtermctl);
// copies the skill into <home>/.claude/skills/agterm and <home>/.codex/skills/agterm (whichever agents exist)
Report skill(const QString &home, const QString &bundle);
// master's FirstRunWelcome: any state at all means this is not a first launch
bool hasPriorState(const QString &stateDir);

QString packageDir(const QString &home);
QString shellQuote(const QString &s);
}
