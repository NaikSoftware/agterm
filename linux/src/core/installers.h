#pragma once

#include <QString>
#include <QStringList>

// master's installers, run unattended on install or update; an explicit home lets tests and smoke use a temp dir.
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

// copies the shipped agent-status package to <home>/.config/elis/agent-status, bakes elisctl's path into the
// wrappers, merges Claude Code hooks, sources the shell integration, and adds the Codex, Pi and OpenCode hooks
Report agentHooks(const QString &home, const QString &bundle, const QString &elisctl, const OpenCode &openCode);
// links <home>/.local/bin/elisctl to elisctl; an elisctl already there is left alone
Report commandLineTool(const QString &home, const QString &elisctl);
// copies the skill into <home>/.claude/skills/elis and <home>/.codex/skills/elis (whichever agents exist)
Report skill(const QString &home, const QString &bundle);

QString packageDir(const QString &home);
QString shellQuote(const QString &s);
}
