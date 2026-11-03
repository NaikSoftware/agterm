#include "launcher.h"

const QList<Launcher> &launchers()
{
    static const QList<Launcher> all{{"terminal", "Terminal", {}},
                                     {"claude", "Claude Code", "claude"},
                                     {"codex", "Codex", "codex"},
                                     {"opencode", "OpenCode", "opencode"},
                                     {"antigravity", "Antigravity", "agy"}};
    return all;
}

const Launcher *launcher(const QString &id)
{
    for (const auto &l : launchers())
        if (l.id == id)
            return &l;
    return nullptr;
}

static QString named(const QString &arg)
{
    const QString base = arg.section(QLatin1Char('/'), -1);
    for (const auto &l : launchers())
        if (!l.command.isEmpty() && l.command == base)
            return l.id;
    return {};
}

QString agentForArgv(QStringList argv)
{
    if (argv.isEmpty())
        return {};
    if (argv[0].startsWith(QLatin1Char('-')))
        argv[0] = argv[0].mid(1); // login shells report -zsh
    if (const QString a = named(argv[0]); !a.isEmpty())
        return a;
    static const QStringList interpreters{"node", "bun", "deno"};
    if (!interpreters.contains(argv[0].section(QLatin1Char('/'), -1)))
        return {};
    for (int i = 1; i < argv.size(); ++i)
        if (!argv[i].startsWith(QLatin1Char('-')))
            return named(argv[i]);
    return {};
}

QString agentForGroup(const QList<QStringList> &group)
{
    for (const auto &argv : group)
        if (const QString a = agentForArgv(argv); !a.isEmpty())
            return a;
    return {};
}

QStringList availableLaunchers(const QString &path, const std::function<bool(const QString &)> &isExecutable)
{
    const QStringList dirs = path.split(QLatin1Char(':'), Qt::SkipEmptyParts);
    QStringList out;
    for (const auto &l : launchers()) {
        bool found = l.command.isEmpty();
        for (int i = 0; !found && i < dirs.size(); ++i)
            found = isExecutable(dirs[i] + QLatin1Char('/') + l.command);
        if (found)
            out << l.id;
    }
    return out;
}
