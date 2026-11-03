// agtermctl: drive a running agterm-qt over its control socket.
#include "paths.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QSet>
#include <QThread>
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
  font inc|dec|reset [--pane left|right]   the session's terminal font size
  recent open                           reopen the most recently closed session
  filepanel [show|hide|toggle]          the session folder tree beside the sidebar
  filepanel width <px>
  notify --title T [--body B]           desktop notification + unseen badge on the session
  session seen                          clear the session's unseen badge without focusing it
  session type <text> | --stdin
  session text [--lines N]              full screen + scrollback
  session status <idle|active|completed|blocked> [--auto-reset] [--blink]
  session go --to next|prev|first|last|next-attention|prev-attention
  keymap reload | list                  re-read keymap.conf; show what each built-in and custom command is bound to
  keymap run <name>                     start a custom command for the target session
  hooks reload | list                   re-read hooks.conf; show each hook's live state
  theme list                            Konsole colour schemes (* = current)
  theme set [name]                      no name: back to the Konsole profile's own scheme
  session overlay open <command> [--cwd DIR] [--wait | --block] [--size-percent N [--width PT] [--height PT]]
                       [--background-color #rrggbb] [--follow] [--pane left|right]
                                        a program over the session (full, floating, or one pane); closes when it exits
  session overlay close | result | text [--lines N] [--pane left|right]
  session overlay hide | show | toggle [--pane left|right]
  session overlay resize (--size-percent N [--width PT] [--height PT] | --width PT | --height PT | --full)
  session hud [open] <message> | --file F [--markdown] [--font-size PT] [--detail T] [--spinner] [--spinner-style S]
              [--position P] [--background-color #rrggbb] [--text-color #rrggbb] [--size-percent N] [--sticky] [--no-frame]
              [--hide-after SECONDS] [--pane left|right]      a passive panel; the session stays typable
  session hud update <message> ...      replaces the whole panel (font size and background stay)
  session hud close
  restore mode [none|rerun|live]        bare: configured / at launch / active; a mode applies from the next launch
  restore capture                       record each pane's foreground command now (rerun mode)
  restore clear                         forget every captured command
  session restore <command> | --none | --clear [--pane left|right]   pin what this pane re-runs (rerun mode)
)";

static QByteArray roundTrip(const QString &path, const QJsonObject &request, QString *error)
{
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(3000))
        return *error = QStringLiteral("cannot connect to %1: %2 (is agterm-qt running?)").arg(path, socket.errorString()), QByteArray();
    socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
    QByteArray line;
    while (!line.endsWith('\n') && socket.waitForReadyRead(30000))
        line += socket.readAll();
    line += socket.readAll();
    if (line.trimmed().isEmpty())
        *error = QStringLiteral("no response from %1").arg(path);
    return line.trimmed().isEmpty() ? QByteArray() : line;
}

static int die(const QString &message)
{
    fprintf(stderr, "agtermctl: %s\n", qPrintable(message));
    return 1;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList flags{"json", "stdin", "all", "no-select", "create-workspace", "auto-reset", "blink", "undoable", "companion",
                            "wait", "block", "follow", "full", "markdown", "sticky", "no-frame", "spinner", "none", "clear"};
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
    if (QStringList{"workspace", "session", "recent", "font", "keymap", "hooks", "theme", "restore"}.contains(cmd) && !pos.isEmpty())
        cmd += QLatin1Char('.') + pos.takeFirst();
    if (cmd == QLatin1String("filepanel") && pos.value(0) == QLatin1String("width"))
        cmd = QStringLiteral("filepanel.width"), pos.removeFirst();
    if (cmd == QLatin1String("session.duplicate") && opt.contains(QStringLiteral("companion")))
        cmd = QStringLiteral("session.companion.duplicate");
    if (cmd == QLatin1String("session.overlay") && !pos.isEmpty())
        cmd += QLatin1Char('.') + pos.takeFirst();
    if (cmd == QLatin1String("session.hud"))
        cmd += QStringList{"open", "update", "close"}.contains(pos.value(0)) ? QLatin1Char('.') + pos.takeFirst() : QStringLiteral(".open");
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
    copy("pane", "pane");
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
    if (cmd == QLatin1String("keymap.run") || cmd == QLatin1String("theme.set"))
        args.insert("name", arg);
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
    if (cmd.startsWith(QLatin1String("session.overlay.")) || cmd.startsWith(QLatin1String("session.hud."))) {
        copy("background-color", "color");
        copy("text-color", "textColor");
        copy("detail", "detail");
        copy("position", "position");
        copy("spinner-style", "spinner");
        copy("html", "html");
        copy("url", "url");
        flag("wait", "wait");
        flag("follow", "follow");
        flag("full", "full");
        flag("markdown", "markdown");
        flag("sticky", "sticky");
        if (opt.contains(QStringLiteral("spinner")) && !args.contains("spinner"))
            args.insert("spinner", true);
        if (opt.contains(QStringLiteral("no-frame")))
            args.insert("frame", false);
        for (const auto &[from, to] : {std::pair{"size-percent", "sizePercent"}})
            if (opt.contains(QLatin1String(from)))
                args.insert(QLatin1String(to), opt.value(QLatin1String(from)).toInt());
        for (const auto &[from, to] : {std::pair{"width", "width"}, {"height", "height"}, {"hide-after", "hideAfter"}, {"font-size", "fontSize"}})
            if (opt.contains(QLatin1String(from)))
                args.insert(QLatin1String(to), opt.value(QLatin1String(from)).toDouble());
        if (cmd == QLatin1String("session.overlay.open") && !arg.isEmpty())
            args.insert("command", arg);
        if (cmd == QLatin1String("session.hud.open") || cmd == QLatin1String("session.hud.update")) {
            if (opt.contains(QStringLiteral("file"))) {
                QFile f(opt.value(QStringLiteral("file")));
                if (!f.open(QIODevice::ReadOnly))
                    return die(QStringLiteral("cannot read %1").arg(f.fileName()));
                args.insert("message", QString::fromUtf8(f.readAll()).trimmed());
            } else {
                args.insert("message", arg);
            }
        }
        if (opt.contains(QStringLiteral("block")) && opt.contains(QStringLiteral("wait")))
            return die(QStringLiteral("--block is mutually exclusive with --wait"));
    }
    if (cmd == QLatin1String("restore.mode") && !arg.isEmpty())
        args.insert("mode", arg);
    if (cmd == QLatin1String("session.restore")) {
        args.insert("mode", opt.contains(QStringLiteral("none")) ? QStringLiteral("none") : opt.contains(QStringLiteral("clear")) ? QStringLiteral("clear") : QStringLiteral("set"));
        if (!arg.isEmpty())
            args.insert("command", arg);
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
    if (target.isEmpty() && (cmd.startsWith(QLatin1String("session.")) || cmd.startsWith(QLatin1String("font.")) || cmd == QLatin1String("notify") || cmd == QLatin1String("keymap.run"))
        && cmd != QLatin1String("session.new"))
        target = qEnvironmentVariable("AGTERM_SESSION_ID"); // a pane addresses itself by default
    if (!target.isEmpty())
        request.insert("target", target);

    const QString path = opt.value(QStringLiteral("socket"), socketPath());
    QString error;
    const QByteArray line = roundTrip(path, request, &error);
    if (line.isEmpty())
        return die(error);

    if (opt.contains(QStringLiteral("json")))
        return fputs(line.constData(), stdout), 0;
    const QJsonObject response = QJsonDocument::fromJson(line).object();
    if (!response.value("ok").toBool())
        return die(response.value("error").toString());
    const QJsonObject result = response.value("result").toObject();
    if (cmd == QLatin1String("session.overlay.open") && opt.contains(QStringLiteral("block"))) {
        // exits with the program's status, printing none of its output
        QJsonObject pollArgs;
        if (args.contains("pane"))
            pollArgs.insert("pane", args.value("pane"));
        const QJsonObject poll{{"cmd", "session.overlay.result"}, {"target", result["id"].toString()}, {"args", pollArgs}};
        for (;;) {
            const QJsonObject r = QJsonDocument::fromJson(roundTrip(path, poll, &error)).object();
            if (r.value("ok").toBool())
                return r["result"]["exitCode"].toInt();
            if (r.value("error").toString() != QLatin1String("overlay still running"))
                return die(r.value("error").toString(error));
            QThread::msleep(200);
        }
    }
    if (result.contains("restore")) {
        const QJsonObject r = result["restore"].toObject();
        printf("configured %s\nat launch  %s\nactive     %s%s\n", qPrintable(r["configured"].toString()), qPrintable(r["requestedAtLaunch"].toString()),
               qPrintable(r["active"].toString()), r["restartRequired"].toBool() ? "\n(restart required)" : "");
        if (r.contains("unavailableReason"))
            printf("live unavailable: %s\n", qPrintable(r["unavailableReason"].toString()));
        return 0;
    }
    if (result.contains("exitCode"))
        return printf("%d\n", result["exitCode"].toInt()), 0;

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
    } else if (result.contains("keymap")) {
        const QJsonObject k = result["keymap"].toObject();
        printf("%s\n", qPrintable(k["path"].toString()));
        for (const auto &v : k["actions"].toArray()) {
            QStringList keys{v.toObject()["chord"].toString()};
            for (const auto &a : v.toObject()["alternates"].toArray())
                keys << a.toString();
            printf("  %-28s %s%s\n", qPrintable(v.toObject()["name"].toString()), qPrintable(keys.join(QLatin1Char('|'))), v.toObject()["marked"].toBool() ? "  (mapped)" : "");
        }
        for (const auto &v : k["commands"].toArray())
            printf("  command \"%s\" %s%s  %s\n", qPrintable(v.toObject()["name"].toString()), qPrintable(v.toObject()["shortcut"].toString()),
                   v.toObject()["errorHud"].toBool() ? " --error-hud" : "", qPrintable(v.toObject()["command"].toString()));
        for (const auto &v : k["diagnostics"].toArray())
            printf("  line %d: %s\n", v.toObject()["line"].toInt(), qPrintable(v.toObject()["message"].toString()));
        printf("menu:\n");
        for (const auto &v : k["menu"].toArray())
            printf("  %-32s %s%s\n", qPrintable(v.toObject()["title"].toString()), qPrintable(v.toObject()["chord"].toString()), v.toObject()["enabled"].toBool() ? "" : "  (disabled)");
    } else if (result.contains("hooks")) {
        const QJsonObject h = result["hooks"].toObject();
        printf("%s\n", qPrintable(h["path"].toString()));
        for (const auto &v : h["hooks"].toArray()) {
            printf("  line %d  on %s %s", v.toObject()["line"].toInt(), qPrintable(v.toObject()["kind"].toString()), qPrintable(v.toObject()["command"].toString()));
            if (v.toObject().contains("runningPid"))
                printf("  [running pid %lld]", qint64(v.toObject()["runningPid"].toDouble()));
            if (v.toObject()["pending"].toInt() || v.toObject()["dropped"].toInt())
                printf("  [pending %d, dropped %d]", v.toObject()["pending"].toInt(), v.toObject()["dropped"].toInt());
            if (v.toObject().contains("lastFailure"))
                printf("  [last failure: %s]", qPrintable(v.toObject()["lastFailure"].toString()));
            printf("%s\n", v.toObject()["retired"].toBool() ? "  (retired)" : "");
        }
        for (const auto &v : h["diagnostics"].toArray())
            printf("  line %d: %s\n", v.toObject()["line"].toInt(), qPrintable(v.toObject()["message"].toString()));
    } else if (result.contains("themes")) {
        for (const auto &v : result["themes"].toArray())
            printf("%s %s\n", v.toString() == result["theme"].toString() ? "*" : " ", qPrintable(v.toString()));
    } else if (result.contains("count") && !result.contains("text")) {
        printf("%d diagnostic(s)\n", result["count"].toInt());
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
