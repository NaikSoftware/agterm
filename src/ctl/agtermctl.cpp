// agtermctl: drive a running agterm-qt over its control socket.
#include "paths.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QSet>
#include <cstdio>

static const char *usage = R"(usage: agtermctl <command> [args] [--target T] [--socket PATH] [--json]

  tree                                  workspaces and sessions
  version
  workspace new [--name N] [--tint COLOR [--tint-on icon,name]]
  workspace rename <name>               (--target: workspace id/prefix/name, default active)
  workspace tint <color|clear> [--on icon,name]   the workspace row only
  session tint <color|clear> [--on icon,name]     red|orange|yellow|green|blue|purple|gray
  workspace delete | select
  workspace focus [on|off|toggle|add]   on: mark this one alone and apply the filter; add: mark without narrowing
  workspace filter [on|off|toggle]      apply or suspend the marked set (off keeps it)
  session new [--name N] [--cwd DIR] [--workspace W | --workspace-name N [--create-workspace]]
              [--command CMD] [--no-select] [--parent SESSION]   (--parent makes a companion)
              [--tint COLOR [--tint-on icon,name]]
  session close [--undoable]           with the GUI's undo grace when Settings allow it; prints (undoable)|(not undoable)
  session close | select | info         (--target: session id/prefix/name, default $AGTERM_SESSION_ID, then active)
  session rename <name>                 empty name reverts to the directory name
  session duplicate [--no-select]
  session duplicate --companion [--no-select]   a companion copying the split layout and each pane's program
  session flag [on|off|toggle]
  session move <workspace> [--index N]
  workspace move --index N
  session split [on|off|toggle] [--axis vertical|horizontal]
  session split close
  session swap
  recent open                           reopen the most recently closed session
  filepanel [show|hide|toggle]          the session folder tree beside the sidebar
  filepanel width <px>
  notify --title T [--body B]           desktop notification + unseen badge on the session
  session seen                          clear the session's unseen badge without focusing it
  session type <text> | --stdin
  session text [--lines N]              full screen + scrollback
  session status <idle|active|completed|blocked> [--auto-reset] [--blink]
  session go --to next|prev|first|last|next-attention|prev-attention
)";

static int die(const QString &message)
{
    fprintf(stderr, "agtermctl: %s\n", qPrintable(message));
    return 1;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList flags{"json", "stdin", "all", "no-select", "create-workspace", "auto-reset", "blink", "undoable", "companion"};
    QStringList pos;
    QHash<QString, QString> opt;
    const QStringList in = app.arguments().mid(1);
    for (int i = 0; i < in.size(); ++i) {
        if (!in[i].startsWith(QLatin1String("--"))) {
            pos << in[i];
            continue;
        }
        const QString name = in[i].mid(2);
        if (name == QLatin1String("help"))
            return fputs(usage, stdout), 0;
        if (flags.contains(name))
            opt.insert(name, QStringLiteral("1"));
        else if (i + 1 < in.size())
            opt.insert(name, in[++i]);
        else
            return die(QStringLiteral("--%1 needs a value").arg(name));
    }
    if (pos.isEmpty())
        return fputs(usage, stderr), 1;

    QString cmd = pos.takeFirst();
    if ((cmd == QLatin1String("workspace") || cmd == QLatin1String("session") || cmd == QLatin1String("recent")) && !pos.isEmpty())
        cmd += QLatin1Char('.') + pos.takeFirst();
    if (cmd == QLatin1String("filepanel") && pos.value(0) == QLatin1String("width"))
        cmd = QStringLiteral("filepanel.width"), pos.removeFirst();
    if (cmd == QLatin1String("session.duplicate") && opt.contains(QStringLiteral("companion")))
        cmd = QStringLiteral("session.companion.duplicate");
    if (cmd == QLatin1String("session.split") && pos.value(0) == QLatin1String("close"))
        cmd = QStringLiteral("session.split.close"), pos.removeFirst();
    const QString arg = pos.value(0);

    QJsonObject args;
    auto copy = [&](const char *from, const char *to) {
        if (opt.contains(QLatin1String(from)))
            args.insert(QLatin1String(to), opt.value(QLatin1String(from)));
    };
    auto flag = [&](const char *from, const char *to) {
        if (opt.contains(QLatin1String(from)))
            args.insert(QLatin1String(to), true);
    };
    copy("name", "name");
    copy("cwd", "cwd");
    copy("workspace", "workspace");
    copy("workspace-name", "workspaceName");
    copy("command", "command");
    copy("to", "to");
    copy("title", "title");
    copy("parent", "parent");
    copy("body", "body");
    flag("create-workspace", "createWorkspace");
    flag("no-select", "noSelect");
    flag("auto-reset", "autoReset");
    flag("blink", "blink");
    flag("undoable", "undoable");
    if (opt.contains(QStringLiteral("lines")))
        args.insert("lines", opt.value(QStringLiteral("lines")).toInt());
    if (opt.contains(QStringLiteral("index")))
        args.insert("index", opt.value(QStringLiteral("index")).toInt());
    if (cmd == QLatin1String("filepanel.width"))
        args.insert("width", arg.toInt());
    if (cmd == QLatin1String("filepanel"))
        args.insert("mode", arg.isEmpty() ? QStringLiteral("toggle") : arg);
    if (QStringList{"session.flag", "session.split", "workspace.focus", "workspace.filter"}.contains(cmd))
        args.insert("mode", arg.isEmpty() ? QStringLiteral("toggle") : arg);
    copy("axis", "axis");
    if (cmd == QLatin1String("session.move"))
        args.insert("workspace", arg);
    if (cmd.endsWith(QLatin1String(".rename")))
        args.insert("name", arg);
    if (cmd == QLatin1String("session.status"))
        args.insert("status", arg);
    if (cmd.endsWith(QLatin1String(".tint"))) {
        args.insert("mode", arg == QLatin1String("clear") ? QStringLiteral("clear") : QStringLiteral("set"));
        if (arg != QLatin1String("clear"))
            args.insert("tint", arg);
        if (opt.contains(QStringLiteral("on")))
            args.insert("tintOn", QJsonArray::fromStringList(opt.value(QStringLiteral("on")).split(QLatin1Char(','))));
    }
    if (cmd.endsWith(QLatin1String(".new")) && opt.contains(QStringLiteral("tint"))) {
        args.insert("tint", opt.value(QStringLiteral("tint")));
        if (opt.contains(QStringLiteral("tint-on")))
            args.insert("tintOn", QJsonArray::fromStringList(opt.value(QStringLiteral("tint-on")).split(QLatin1Char(','))));
    } else if (opt.contains(QStringLiteral("tint-on"))) {
        args.insert("tintOn", QJsonArray()); // the app refuses a placement without a colour
    }
    if (cmd == QLatin1String("session.type")) {
        if (opt.contains(QStringLiteral("stdin"))) {
            QFile f;
            if (!f.open(stdin, QIODevice::ReadOnly))
                return die(QStringLiteral("cannot read stdin"));
            args.insert("text", QString::fromUtf8(f.readAll()));
        } else {
            args.insert("text", arg);
        }
    }

    QJsonObject request{{"cmd", cmd}, {"args", args}};
    QString target = opt.value(QStringLiteral("target"));
    if (target.isEmpty() && (cmd.startsWith(QLatin1String("session.")) || cmd == QLatin1String("notify")) && cmd != QLatin1String("session.new"))
        target = qEnvironmentVariable("AGTERM_SESSION_ID"); // a pane addresses itself by default
    if (!target.isEmpty())
        request.insert("target", target);

    const QString path = opt.value(QStringLiteral("socket"), socketPath());
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(3000))
        return die(QStringLiteral("cannot connect to %1: %2 (is agterm-qt running?)").arg(path, socket.errorString()));
    socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
    QByteArray line;
    while (!line.endsWith('\n') && socket.waitForReadyRead(30000))
        line += socket.readAll();
    line += socket.readAll();
    if (line.trimmed().isEmpty())
        return die(QStringLiteral("no response from %1").arg(path));

    if (opt.contains(QStringLiteral("json")))
        return fputs(line.constData(), stdout), 0;
    const QJsonObject response = QJsonDocument::fromJson(line).object();
    if (!response.value("ok").toBool())
        return die(response.value("error").toString());
    const QJsonObject result = response.value("result").toObject();

    if (result.contains("tree")) {
        for (const auto &wv : result["tree"]["workspaces"].toArray()) {
            const auto w = wv.toObject();
            printf("%s  %s\n", qPrintable(w["id"].toString()), qPrintable(w["name"].toString()));
            for (const auto &sv : w["sessions"].toArray()) {
                const auto s = sv.toObject();
                printf("  %s %s %-24s %-9s %s\n", s["active"].toBool() ? "*" : " ", qPrintable(s["id"].toString()),
                       qPrintable(s["name"].toString()), qPrintable(s["status"].toString()), qPrintable(s["cwd"].toString()));
            }
        }
    } else if (result.contains("session")) {
        const auto s = result["session"].toObject();
        for (auto it = s.begin(); it != s.end(); ++it)
            printf("%-14s %s\n", qPrintable(it.key()), qPrintable(it.value().toVariant().toString()));
    } else if (result.contains("text")) {
        fputs(result["text"].toString().toUtf8().constData(), stdout);
        if (!result["text"].toString().endsWith(QLatin1Char('\n')))
            putchar('\n');
    } else if (result.contains("undoable")) {
        printf("ok %s\n", result["undoable"].toBool() ? "(undoable)" : "(not undoable)");
    } else if (cmd.endsWith(QLatin1String(".new")) || cmd == QLatin1String("session.duplicate") || cmd == QLatin1String("session.companion.duplicate")
               || cmd == QLatin1String("recent.open")) {
        printf("%s\n", qPrintable(result["id"].toString()));
    }
    return 0;
}
