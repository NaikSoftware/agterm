#include "installers.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>

namespace Install {

static const char *const shellMarker = "# >>> agterm agent-status >>>";
static const char *const shellEnd = "# <<< agterm agent-status <<<";
static const char *const bakeMarker = "# >>> agterm agtermctl path (installer-baked) >>>";

QString packageDir(const QString &home)
{
    return home + QStringLiteral("/.config/agterm-qt/agent-status");
}

QString shellQuote(const QString &s)
{
    return QLatin1Char('\'') + QString(s).replace(QLatin1Char('\''), QStringLiteral("'\\''")) + QLatin1Char('\'');
}

// "~/x" for a path under home, as master's messages read
static QString tilde(const QString &home, const QString &path)
{
    return path.startsWith(home + QLatin1Char('/')) ? QStringLiteral("~") + path.mid(home.size()) : path;
}

enum class Read { Absent, Ok, Unreadable };

static Read readText(const QString &path, QString *out)
{
    QFile f(path);
    if (!QFileInfo::exists(path))
        return Read::Absent;
    if (!f.open(QIODevice::ReadOnly))
        return Read::Unreadable;
    const QByteArray raw = f.readAll();
    *out = QString::fromUtf8(raw);
    return out->toUtf8() == raw ? Read::Ok : Read::Unreadable; // not UTF-8: leave it alone
}

// writes through a symlink (a dotfiles-managed link survives), keeps the file's mode, and backs the old one up as .bak
static bool writeText(const QString &path, const QString &text, bool backup)
{
    const QFileInfo info(path);
    const QString target = info.isSymLink() ? info.canonicalFilePath() : path;
    const bool existed = QFileInfo::exists(target);
    const QFileDevice::Permissions mode = existed ? QFile::permissions(target) : QFileDevice::Permissions();
    if (backup && existed) {
        QFile::remove(path + QStringLiteral(".bak"));
        if (!QFile::copy(target, path + QStringLiteral(".bak")))
            return false;
        QFile::setPermissions(path + QStringLiteral(".bak"), mode);
    }
    QDir().mkpath(QFileInfo(target).absolutePath());
    QSaveFile f(target.isEmpty() ? path : target);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.write(text.toUtf8());
    if (!f.commit())
        return false;
    if (existed)
        QFile::setPermissions(target, mode);
    return true;
}

static bool copyTree(const QString &from, const QString &to)
{
    QDir(to).removeRecursively();
    QDirIterator it(from, QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    if (!QDir().mkpath(to))
        return false;
    while (it.hasNext()) {
        const QFileInfo fi = it.nextFileInfo();
        const QString dest = to + QLatin1Char('/') + QDir(from).relativeFilePath(fi.filePath());
        if (fi.isDir() ? !QDir().mkpath(dest) : !QFile::copy(fi.filePath(), dest))
            return false;
        if (!fi.isDir())
            QFile::setPermissions(dest, fi.permissions() | QFileDevice::WriteOwner);
    }
    return true;
}

static bool bake(const QString &script, const QString &agtermctl)
{
    QString text;
    if (readText(script, &text) != Read::Ok)
        return false;
    QStringList lines = text.split(QLatin1Char('\n'));
    if (const qsizetype at = lines.indexOf(QLatin1String(bakeMarker)); at >= 0)
        lines.remove(at, qMin(qsizetype(5), lines.size() - at));
    lines.insert(1, QStringLiteral("%1\nif [ -z \"${AGTERMCTL:-}\" ]; then\n  AGTERMCTL=%2\n  [ -x \"$AGTERMCTL\" ] || AGTERMCTL=\"$(command -v agtermctl || true)\"\nfi")
                        .arg(QLatin1String(bakeMarker), shellQuote(agtermctl)));
    return writeText(script, lines.join(QLatin1Char('\n')), false);
}

// ~/.claude/settings.json: append each status hook once, migrating commands an older install wrote; "" or why it was skipped
static bool mergeClaude(const QString &home, const QString &pkg, QString *error)
{
    const QString path = home + QStringLiteral("/.claude/settings.json");
    QString text;
    const Read read = readText(path, &text);
    if (read == Read::Unreadable)
        return false;
    QJsonObject root;
    if (read == Read::Ok && !text.trimmed().isEmpty()) {
        const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8());
        if (!doc.isObject())
            return false;
        root = doc.object();
    }
    static const QList<std::tuple<const char *, const char *, const char *>> wanted{
        {"UserPromptSubmit", nullptr, "active --blink"}, {"PostToolUse", nullptr, "active --blink"}, {"Stop", nullptr, "completed --auto-reset"},
        {"PermissionRequest", nullptr, "blocked"},       {"Notification", "permission_prompt", "blocked"}};
    if (root.contains("hooks") && !root.value("hooks").isObject())
        return false;
    QJsonObject hooks = root.value("hooks").toObject();
    for (const auto &[event, matcher, state] : wanted) {
        if (!hooks.contains(QLatin1String(event)))
            continue;
        if (!hooks.value(QLatin1String(event)).isArray())
            return false;
        for (const auto &v : hooks.value(QLatin1String(event)).toArray())
            if (!v.isObject())
                return false;
    }
    if (root.contains("env") && (!root.value("env").isObject() || (root.value("env").toObject().contains("CLAUDE_CODE_PLUGIN_DIRS") && !root.value("env").toObject().value("CLAUDE_CODE_PLUGIN_DIRS").isString())))
        return false;
    const QString adapter = pkg + QStringLiteral("/agterm-claude-status.sh"), wrapper = pkg + QStringLiteral("/agterm-agent-status.sh");
    const QString cmd = shellQuote(adapter) + QLatin1Char(' ');
    // an older agterm-qt install (scripts/install-claude-hooks.sh) or a raw wrapper hook: same state, our adapter now
    static const QRegularExpression older(QStringLiteral("^'?[^ ']*agent-status/agterm-(claude|agent)-status\\.sh'? (.+)$"));
    for (const auto &[event, matcher, state] : wanted) {
        QJsonArray entries = hooks.value(QLatin1String(event)).toArray();
        bool present = false;
        for (qsizetype i = 0; i < entries.size(); ++i) {
            QJsonObject entry = entries[i].toObject();
            QJsonArray list = entry.value("hooks").toArray();
            for (qsizetype j = 0; j < list.size(); ++j) {
                QJsonObject h = list[j].toObject();
                QString c = h.value("command").toString();
                if (const auto m = older.match(c); m.hasMatch() && !c.contains(adapter)) {
                    c = cmd + m.captured(2);
                    h.insert("command", c);
                    list[j] = h;
                }
                present |= c.contains(adapter) || c.contains(wrapper);
            }
            entry.insert("hooks", list);
            entries[i] = entry;
        }
        if (!present) {
            QJsonObject entry{{"hooks", QJsonArray{QJsonObject{{"type", "command"}, {"command", cmd + QLatin1String(state)}}}}};
            if (matcher)
                entry.insert("matcher", QLatin1String(matcher));
            entries << entry;
        }
        hooks.insert(QLatin1String(event), entries);
    }
    root.insert("hooks", hooks);
    QJsonObject env = root.value("env").toObject();
    const QString mod = pkg + QStringLiteral("/claude-mods/swarm-companion");
    QStringList dirs = env.value("CLAUDE_CODE_PLUGIN_DIRS").toString().split(QLatin1Char(':'), Qt::SkipEmptyParts);
    if (!dirs.contains(mod)) {
        dirs << mod;
        env.insert("CLAUDE_CODE_PLUGIN_DIRS", dirs.join(QLatin1Char(':')));
        root.insert("env", env);
    }
    const QString out = QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Indented));
    if (read == Read::Ok && QJsonDocument::fromJson(text.toUtf8()).object() == root)
        return true; // nothing changed: the file is not rewritten
    if (!writeText(path, out, read == Read::Ok))
        *error = QStringLiteral("Could not write %1.").arg(path);
    return true;
}

static QString shellRc(const QString &home, const QString &pkg, QString *error)
{
    QList<std::pair<QString, QString>> files{{home + QStringLiteral("/.zshrc"), QStringLiteral("integration.sh")},
                                             {home + QStringLiteral("/.bashrc"), QStringLiteral("integration.sh")}};
    if (QFileInfo(home + QStringLiteral("/.config/fish")).isDir())
        files.append({home + QStringLiteral("/.config/fish/config.fish"), QStringLiteral("integration.fish")});
    for (const auto &[path, script] : files) {
        QString text;
        if (readText(path, &text) == Read::Unreadable || text.contains(QLatin1String(shellMarker)))
            continue;
        if (!text.isEmpty())
            text += text.endsWith(QLatin1Char('\n')) ? QStringLiteral("\n") : QStringLiteral("\n\n");
        text += QStringLiteral("%1\nsource %2\n%3\n").arg(QLatin1String(shellMarker), shellQuote(pkg + QStringLiteral("/shell/") + script), QLatin1String(shellEnd));
        if (!writeText(path, text, false))
            return *error = QStringLiteral("Could not write %1.").arg(path), QString();
    }
    return {};
}

enum class Codex { Merged, AlreadyConfigured, HooksExist, Unreadable, NoCodex };

static QString codexBlock(const QString &pkg)
{
    static const QList<std::pair<const char *, const char *>> events{{"SessionStart", "session-start"}, {"UserPromptSubmit", "user-prompt-submit"},
                                                                     {"PreToolUse", "pre-tool-use"},    {"PostToolUse", "post-tool-use"},
                                                                     {"PermissionRequest", "permission-request"}, {"Stop", "stop"}};
    const QString w = shellQuote(pkg + QStringLiteral("/agterm-codex-status.sh"));
    QStringList stanzas;
    for (const auto &[event, action] : events) {
        QString command = w + QLatin1Char(' ') + QLatin1String(action);
        command.replace(QLatin1Char('\\'), QStringLiteral("\\\\")).replace(QLatin1Char('"'), QStringLiteral("\\\""));
        stanzas << QStringLiteral("[[hooks.%1]]\n[[hooks.%1.hooks]]\ntype = \"command\"\ncommand = \"%2\"").arg(QLatin1String(event), command);
    }
    return QStringLiteral("%1\n%2\n%3\n").arg(QLatin1String(shellMarker), stanzas.join(QStringLiteral("\n\n")), QLatin1String(shellEnd));
}

// shortcut: no TOML parser here, so an unparseable config.toml is not detected; a top-level hooks key is found by line
static Codex mergeCodex(const QString &home, const QString &pkg, QString *error)
{
    if (!QFileInfo(home + QStringLiteral("/.codex")).isDir())
        return Codex::NoCodex;
    const QString path = home + QStringLiteral("/.codex/config.toml");
    QString text;
    const Read read = readText(path, &text);
    if (read == Read::Unreadable)
        return Codex::Unreadable;
    const QString block = codexBlock(pkg);
    QString out;
    if (const qsizetype begin = text.indexOf(QLatin1String(shellMarker)); begin >= 0) {
        const qsizetype end = text.indexOf(QLatin1String(shellEnd), begin);
        if (end < 0 || !text.mid(begin, end - begin).contains(QLatin1String("agterm-codex-status.sh")))
            return Codex::HooksExist; // a foreign block under our marker
        // tables Codex appended inside the block (its trust state) stay byte for byte
        const QString inner = text.mid(begin, end - begin);
        const qsizetype state = inner.indexOf(QRegularExpression(QStringLiteral("\n\\n?\\[hooks\\.state")));
        QString kept = state < 0 ? QString() : inner.mid(state);
        while (kept.endsWith(QLatin1Char('\n')))
            kept.chop(1);
        QString fresh = block;
        fresh.insert(fresh.lastIndexOf(QLatin1String(shellEnd)) - 1, kept);
        out = text.left(begin) + fresh + text.mid(end + qsizetype(strlen(shellEnd)) + (text.mid(end + qsizetype(strlen(shellEnd))).startsWith(QLatin1Char('\n')) ? 1 : 0));
        if (out == text)
            return Codex::AlreadyConfigured;
    } else if (text.trimmed().isEmpty()) {
        out = block;
    } else {
        QStringList lines = text.split(QLatin1Char('\n'));
        static const QRegularExpression header(QStringLiteral("^\\s*\\[")), hooksHeader(QStringLiteral("^\\s*\\[\\[?\\s*hooks\\s*[\\].]")),
            hooksKey(QStringLiteral("^\\s*\"?hooks\"?\\s*[=.]")), notify(QStringLiteral("^\\s*notify\\s*=.*codex-notify\\.sh"));
        bool topLevel = true;
        qsizetype notifyLine = -1;
        for (qsizetype i = 0; i < lines.size(); ++i) {
            if (hooksHeader.match(lines[i]).hasMatch() || (topLevel && hooksKey.match(lines[i]).hasMatch()))
                return Codex::HooksExist;
            if (header.match(lines[i]).hasMatch())
                topLevel = false;
            else if (topLevel && notifyLine < 0 && notify.match(lines[i]).hasMatch())
                notifyLine = i;
        }
        if (notifyLine >= 0)
            lines.removeAt(notifyLine); // master's codex-notify.sh predates the hooks
        out = lines.join(QLatin1Char('\n'));
        out += (out.endsWith(QLatin1Char('\n')) ? QStringLiteral("\n") : QStringLiteral("\n\n")) + block;
    }
    if (!writeText(path, out, read == Read::Ok && !text.trimmed().isEmpty()))
        *error = QStringLiteral("Could not write %1.").arg(path);
    return Codex::Merged;
}

enum class Plugin { Installed, AlreadyConfigured, UserOwned, Unreadable, WriteFailed };

// an extension file we own (it carries our marker): written when absent or different, never over a user's own
static Plugin installOwned(const QString &source, const QString &dest, const QString &marker)
{
    QString want, have;
    readText(source, &want);
    const Read read = readText(dest, &have);
    if (read == Read::Unreadable)
        return Plugin::Unreadable;
    if (read == Read::Ok && !have.contains(marker))
        return Plugin::UserOwned;
    if (read == Read::Ok && have == want)
        return Plugin::AlreadyConfigured;
    return writeText(dest, want, false) ? Plugin::Installed : Plugin::WriteFailed;
}

Report agentHooks(const QString &home, const QString &bundle, const QString &agtermctl, const OpenCode &openCode)
{
    Report r;
    const QString pkg = packageDir(home);
    if (!QFileInfo(bundle + QStringLiteral("/agterm-agent-status.sh")).isFile())
        return r.error = QStringLiteral("The agent-status scripts are not bundled in this build."), r;
    QString text;
    if (readText(bundle + QStringLiteral("/pi/agterm-status.ts"), &text) != Read::Ok)
        return r.error = QStringLiteral("The Pi status extension is not bundled in this build."), r;
    if (!text.contains(QLatin1String("// agterm-pi-status-extension")))
        return r.error = QStringLiteral("The bundled Pi status extension is missing its ownership marker."), r;
    for (const auto &[file, marker, v] : {std::tuple{"opencode/agterm-status.js", "// agterm-opencode-status-plugin", 1},
                                          std::tuple{"opencode/agterm-v2/tui.js", "// agterm-opencode-v2-status-plugin", 2}}) {
        if (readText(bundle + QLatin1Char('/') + QLatin1String(file), &text) != Read::Ok)
            return r.error = QStringLiteral("The OpenCode v%1 status plugin is not bundled in this build.").arg(v), r;
        if (!text.contains(QLatin1String(marker)))
            return r.error = QStringLiteral("The OpenCode v%1 status plugin is missing its ownership marker.").arg(v), r;
    }
    if (!copyTree(bundle, pkg))
        return r.error = QStringLiteral("Could not copy the agent-status scripts to %1.").arg(pkg), r;
    if (QFileInfo(agtermctl).isExecutable())
        for (const char *script : {"agterm-agent-status.sh", "agterm-codex-status.sh"})
            bake(pkg + QLatin1Char('/') + QLatin1String(script), agtermctl);

    QString error;
    const bool claude = mergeClaude(home, pkg, &error);
    if (error.isEmpty())
        shellRc(home, pkg, &error);
    const Codex codex = error.isEmpty() ? mergeCodex(home, pkg, &error) : Codex::NoCodex;
    if (!error.isEmpty())
        return r.error = error, r;

    QString piLine;
    bool warn = !claude || codex == Codex::HooksExist || codex == Codex::Unreadable;
    if (!QFileInfo(home + QStringLiteral("/.pi/agent")).isDir()) {
        piLine = QStringLiteral("No ~/.pi/agent found, so Pi's lifecycle extension was skipped. Start Pi once, then run this again.");
    } else {
        const Plugin pi = installOwned(bundle + QStringLiteral("/pi/agterm-status.ts"), home + QStringLiteral("/.pi/agent/extensions/agterm-status.ts"),
                                       QStringLiteral("// agterm-pi-status-extension"));
        static const QHash<Plugin, QString> lines{
            {Plugin::Installed, "Pi lifecycle extension installed to ~/.pi/agent/extensions/agterm-status.ts. Restart Pi or run /reload."},
            {Plugin::AlreadyConfigured, "Pi lifecycle extension is already current at ~/.pi/agent/extensions/agterm-status.ts."},
            {Plugin::UserOwned, "~/.pi/agent/extensions/agterm-status.ts is user-owned, so agterm left it untouched."},
            {Plugin::Unreadable, "~/.pi/agent/extensions/agterm-status.ts exists but could not be read, so agterm left it untouched."},
            {Plugin::WriteFailed, "Pi's lifecycle extension couldn't be written to ~/.pi/agent/extensions/ (check that directory's permissions), so it was skipped."}};
        piLine = lines.value(pi);
        warn |= pi == Plugin::UserOwned || pi == Plugin::Unreadable || pi == Plugin::WriteFailed;
    }

    QString openCodeLine;
    const QString legacy = home + QStringLiteral("/.config/opencode");
    if (openCode.version == 0) {
        openCodeLine = QStringLiteral("OpenCode status plugin installation was skipped.");
    } else if (openCode.version == 2 && openCode.v2Dir.isEmpty()) {
        openCodeLine = QStringLiteral("OpenCode v2 installation was skipped because its configuration directory could not be determined from your login shell. "
                                      "Check shell startup and OPENCODE_CONFIG_DIR, then run this again.");
        warn = true;
    } else {
        const QString cfg = openCode.version == 2 ? openCode.v2Dir : legacy;
        if (openCode.version < 1 || !QFileInfo(cfg).isDir()) {
            openCodeLine = QStringLiteral("No %1 found, so the OpenCode plugin was skipped. Start OpenCode once, then run this again. "
                                          "Coarse shell detection for opencode is off by default.").arg(tilde(home, cfg));
        } else {
            const bool v2 = openCode.version == 2;
            const QString dest = cfg + (v2 ? QStringLiteral("/plugins/agterm-v2/tui.js") : QStringLiteral("/plugins/agterm-status.js"));
            const Plugin p = installOwned(bundle + (v2 ? QStringLiteral("/opencode/agterm-v2/tui.js") : QStringLiteral("/opencode/agterm-status.js")), dest,
                                          v2 ? QStringLiteral("// agterm-opencode-v2-status-plugin") : QStringLiteral("// agterm-opencode-status-plugin"));
            const QString v = v2 ? QStringLiteral("v2") : QStringLiteral("v1");
            static const QHash<Plugin, QString> lines{{Plugin::Installed, "OpenCode %1 status plugin installed to %2. Restart OpenCode."},
                                                      {Plugin::AlreadyConfigured, "OpenCode %1 status plugin is already current at %2."},
                                                      {Plugin::UserOwned, "%2 is user-owned, so the OpenCode %1 plugin was left untouched."},
                                                      {Plugin::Unreadable, "%2 could not be read, so the OpenCode %1 plugin was left untouched."},
                                                      {Plugin::WriteFailed, "OpenCode %1 plugin couldn't be written to %2 (check permissions), so it was skipped."}};
            openCodeLine = lines.value(p).arg(v, dest);
            warn |= p == Plugin::UserOwned || p == Plugin::Unreadable || p == Plugin::WriteFailed;
            const QString old = cfg + QStringLiteral("/plugins/agterm-status.js");
            QString oldText;
            if (v2 && (p == Plugin::Installed || p == Plugin::AlreadyConfigured) && QFileInfo::exists(old)) { // v2 replaces the v1 plugin
                warn = true;
                if (readText(old, &oldText) != Read::Ok)
                    openCodeLine = QStringLiteral("OpenCode v2 status plugin is installed, but %1 could not be read and was left untouched.").arg(old);
                else if (!oldText.contains(QLatin1String("// agterm-opencode-status-plugin")))
                    openCodeLine = QStringLiteral("OpenCode v2 status plugin is installed, but %1 is user-owned and was left untouched.").arg(old);
                else if (!QFile::remove(old))
                    openCodeLine = QStringLiteral("OpenCode v2 status plugin is installed, but the v1 plugin at %1 could not be safely removed. Check permissions and run this again.").arg(old);
                else
                    warn = false;
            }
        }
    }

    const QString approve = QStringLiteral("Run /hooks in Codex to review and approve them before they take effect.");
    const QString manual = QStringLiteral("See the Add Codex hooks by hand section of the agterm docs for the block to add, then run /hooks in Codex.");
    static const QHash<Codex, QString> codexLines{
        {Codex::Merged, "Codex lifecycle hooks merged into ~/.codex/config.toml (any old codex-notify.sh notify line was removed). "},
        {Codex::AlreadyConfigured, "Codex lifecycle hooks are already present in ~/.codex/config.toml. "},
        {Codex::HooksExist, "Your ~/.codex/config.toml already defines its own hooks, so agterm left it untouched. "},
        {Codex::Unreadable, "Your ~/.codex/config.toml exists but couldn't be read, so agterm left it untouched."},
        {Codex::NoCodex, "No ~/.codex found, so Codex hooks were skipped. Install Codex, then run this again."}};
    QString codexLine = codexLines.value(codex);
    if (codex == Codex::Merged || codex == Codex::AlreadyConfigured)
        codexLine += approve;
    else if (codex == Codex::HooksExist)
        codexLine += manual;

    r.warning = warn;
    r.title = warn ? QStringLiteral("Agent Status Hooks Installed — with a warning") : QStringLiteral("Agent Status Hooks Installed");
    r.lines = {QStringLiteral("Scripts installed to %1.").arg(pkg),
               claude ? QStringLiteral("Claude Code hooks and the teammates companion mod merged into ~/.claude/settings.json.")
                      : QStringLiteral("Your ~/.claude/settings.json couldn't be safely read or merged, so the Claude Code hooks were NOT added (the file was left "
                                       "untouched). It is unreadable, not valid JSON, or has a hooks entry in a shape we don't recognize. Fix it and run this "
                                       "again, or add the hooks manually."),
               codexLine,
               piLine,
               openCodeLine,
               QStringLiteral("The source line was added to ~/.zshrc, ~/.bashrc (and ~/.config/fish/config.fish if fish is installed)."),
               QString(),
               QStringLiteral("Open a new terminal for the shell integration to take effect.")};
    return r;
}

Report commandLineTool(const QString &home, const QString &agtermctl)
{
    Report r;
    if (!QFileInfo(agtermctl).isExecutable())
        return r.error = QStringLiteral("agtermctl is not bundled in this build."), r;
    const QString bin = home + QStringLiteral("/.local/bin"), link = bin + QStringLiteral("/agtermctl");
    const QFileInfo existing(link);
    const bool onPath = qEnvironmentVariable("PATH").split(QLatin1Char(':')).contains(bin);
    const QString pathNote = onPath ? QString() : QStringLiteral("~/.local/bin is not on your PATH; add it in your shell profile.");
    if (existing.exists() || existing.isSymLink()) {
        if (existing.canonicalFilePath() == QFileInfo(agtermctl).canonicalFilePath()) {
            r.title = QStringLiteral("Command Line Tool Installed");
            r.lines = {QStringLiteral("agtermctl is already at ~/.local/bin/agtermctl.")};
        } else {
            r.title = QStringLiteral("Command Line Tool Not Installed");
            r.warning = true;
            r.lines = {QStringLiteral("~/.local/bin/agtermctl already exists and is not this build's agtermctl, so it was left untouched.")};
        }
    } else {
        if (!QDir().mkpath(bin) || !QFile::link(agtermctl, link))
            return r.error = QStringLiteral("Could not link %1 to %2.").arg(link, agtermctl), r;
        r.title = QStringLiteral("Command Line Tool Installed");
        r.lines = {QStringLiteral("agtermctl was linked into ~/.local/bin/agtermctl. Open a new terminal and run “agtermctl --help”.")};
    }
    if (!pathNote.isEmpty())
        r.lines << pathNote;
    return r;
}

Report skill(const QString &home, const QString &bundle)
{
    Report r;
    if (!QFileInfo(bundle + QStringLiteral("/SKILL.md")).isFile())
        return r.error = QStringLiteral("The agent skill is not bundled in this build."), r;
    QList<std::pair<QString, QString>> targets; // agent, its skills dir
    if (QFileInfo(home + QStringLiteral("/.claude")).isDir())
        targets.append({QStringLiteral("Claude Code"), home + QStringLiteral("/.claude/skills")});
    if (QFileInfo(home + QStringLiteral("/.codex")).isDir())
        targets.append({QStringLiteral("Codex"), home + QStringLiteral("/.codex/skills")});
    if (targets.isEmpty())
        targets.append({QStringLiteral("Claude Code"), home + QStringLiteral("/.claude/skills")});
    QStringList installed, skipped;
    bool fresh = false;
    for (const auto &[agent, dir] : targets) {
        const QString dest = dir + QStringLiteral("/agterm");
        const QFileInfo present(dest);
        if (present.exists() || present.isSymLink()) {
            QString text;
            if (readText(dest + QStringLiteral("/SKILL.md"), &text) != Read::Ok || !text.contains(QLatin1String("<!-- agterm-skill -->"))) {
                skipped << QStringLiteral("  • %1: a different 'agterm' skill is already there — left untouched").arg(agent);
                continue;
            }
        }
        fresh |= !QFileInfo(dir).isDir();
        if (!QDir().mkpath(dir) || !copyTree(bundle, dest)) {
            skipped << QStringLiteral("  • %1: could not write %2").arg(agent, dest);
            continue;
        }
        installed << QStringLiteral("  • %1: %2").arg(agent, dest);
    }
    r.warning = installed.isEmpty() || !skipped.isEmpty();
    r.title = installed.isEmpty() ? QStringLiteral("Skill Not Installed") : QStringLiteral("Agent Skill Installed");
    if (installed.isEmpty())
        r.lines << QStringLiteral("The skill was not installed.");
    else
        r.lines << QStringLiteral("Installed for:") << installed << QString()
                << QStringLiteral("The agent uses it automatically when you ask it to control agterm-qt. It drives the app via the agtermctl CLI, so install "
                                  "that too if you haven't: Help ▸ Install Command Line Tool…");
    if (!skipped.isEmpty())
        r.lines << QString() << QStringLiteral("Skipped:") << skipped;
    if (fresh && !installed.isEmpty())
        r.lines << QString() << QStringLiteral("A skills directory was created for the first time — restart any running agent session so it picks up the new skill.");
    return r;
}

bool hasPriorState(const QString &stateDir)
{
    for (const char *name : {"settings.json", "workspaces.json", "windows.json", "windows"})
        if (QFileInfo::exists(stateDir + QLatin1Char('/') + QLatin1String(name)))
            return true;
    return false;
}

}
