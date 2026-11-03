#include "keymap.h"

#include <QRegularExpression>
#include <QSet>

QString configDirectory(const QString &setting, const QString &stateDirEnv, const QString &home)
{
    if (!setting.isEmpty())
        return setting;
    if (!stateDirEnv.isEmpty())
        return stateDirEnv + QStringLiteral("/config");
    return home + QStringLiteral("/.config/agterm-qt");
}

const QStringList &masterBuiltinActions()
{
    static const QStringList names{
        "new_window", "rename_window", "delete_window", "previous_window", "next_window", "new_workspace", "rename_workspace",
        "delete_workspace", "new_session", "open_directory", "rename_session", "duplicate_session", "new_companion",
        "duplicate_companion", "close_session", "reopen_recent", "undo_close", "clear_status", "increase_font_size",
        "decrease_font_size", "reset_font_size", "toggle_split", "toggle_horizontal_split", "toggle_scratch",
        "toggle_terminal_zoom", "toggle_overlay", "toggle_search", "toggle_sidebar", "toggle_file_panel", "select_theme",
        "toggle_fullscreen", "toggle_flagged_view", "toggle_flag", "focus_workspace", "toggle_workspace_filter",
        "previous_workspace", "next_workspace", "toggle_workspace_collapse", "focus_left_pane", "focus_right_pane",
        "previous_session", "next_session", "previous_attention_session", "next_attention_session", "first_session",
        "last_session", "quick_terminal", "session_palette", "command_palette", "custom_command_palette", "show_attention",
        "dashboard", "attach_remote", "edit_flagged_sessions", "edit_focused_workspaces"};
    return names;
}

// Ctrl, Alt, Shift, Meta in that order, so equal chords compare equal as strings
static QString joinChord(const QSet<QString> &mods, const QString &key)
{
    QString out;
    for (const char *m : {"Ctrl", "Alt", "Shift", "Meta"})
        if (mods.contains(QLatin1String(m)))
            out += QLatin1String(m) + QLatin1Char('+');
    return out + key;
}

// one Qt portable chord ("Shift+Ctrl+N", "Ctrl++") in joinChord's order
static QString normalizeChord(const QString &chord)
{
    QSet<QString> mods;
    QString rest = chord.trimmed();
    for (bool found = true; found;) {
        found = false;
        for (const char *m : {"Ctrl+", "Alt+", "Shift+", "Meta+"})
            if (rest.size() > int(strlen(m)) && rest.startsWith(QLatin1String(m))) {
                mods << QString::fromLatin1(m).chopped(1);
                rest = rest.mid(int(strlen(m)));
                found = true;
            }
    }
    return joinChord(mods, rest);
}

static QString normalizeSequence(const QString &seq)
{
    QStringList chords;
    for (const QString &c : seq.split(QStringLiteral(", ")))
        chords << normalizeChord(c);
    return chords.join(QStringLiteral(", "));
}

// one kitty chord ("cmd+shift+e") as a portable Qt chord; *startsShortcut: it has a real modifier or is a function key
static QString parseChord(const QString &text, bool *startsShortcut)
{
    static const QHash<QString, QString> named{{"tab", "Tab"},       {"space", "Space"},     {"return", "Return"},  {"enter", "Return"},
                                               {"delete", "Backspace"}, {"backspace", "Backspace"}, {"escape", "Esc"}, {"esc", "Esc"},
                                               {"left", "Left"},     {"right", "Right"},     {"up", "Up"},          {"down", "Down"},
                                               {"home", "Home"},     {"end", "End"},         {"pageup", "PgUp"},    {"pagedown", "PgDown"},
                                               {"insert", "Ins"},    {"del", "Del"}};
    // what Shift types on a US layout, which is the key Qt reports with Shift held
    static const QHash<QChar, QChar> shifted{{'1', '!'}, {'2', '@'}, {'3', '#'}, {'4', '$'},  {'5', '%'}, {'6', '^'}, {'7', '&'},
                                             {'8', '*'}, {'9', '('}, {'0', ')'}, {'-', '_'},  {'=', '+'}, {'[', '{'}, {']', '}'},
                                             {';', ':'}, {'\'', '"'}, {',', '<'}, {'.', '>'}, {'/', '?'}, {'\\', '|'}, {'`', '~'}};
    const QStringList parts = text.split(QLatin1Char('+'));
    if (parts.isEmpty() || parts.contains(QString()))
        return {};
    QSet<QString> mods;
    bool cmd = false, other = false;
    for (int i = 0; i < parts.size() - 1; ++i) {
        const QString m = parts[i].toLower();
        if (m == QLatin1String("ctrl") || m == QLatin1String("control"))
            mods << QStringLiteral("Ctrl"), other = true;
        else if (m == QLatin1String("shift"))
            mods << QStringLiteral("Shift"), other = true;
        else if (m == QLatin1String("alt") || m == QLatin1String("opt") || m == QLatin1String("option"))
            mods << QStringLiteral("Alt"), other = true;
        else if (m == QLatin1String("super") || m == QLatin1String("meta"))
            mods << QStringLiteral("Meta");
        else if (m == QLatin1String("cmd") || m == QLatin1String("command"))
            cmd = true;
        else
            return {};
    }
    if (cmd) {
        mods << QStringLiteral("Ctrl") << QStringLiteral("Shift");
        if (other)
            mods << QStringLiteral("Alt");
    }
    const QString k = parts.last().toLower();
    QString key;
    bool function = false;
    if (named.contains(k)) {
        key = named.value(k);
    } else if (static const QRegularExpression fn(QStringLiteral("^f([1-9]|1[0-9]|20)$")); fn.match(k).hasMatch()) {
        key = k.toUpper();
        function = true;
    } else if (k.size() == 1 && k[0].isPrint() && !k[0].isSpace()) {
        key = k.toUpper();
        if (mods.contains(QStringLiteral("Shift")) && shifted.contains(k[0]))
            key = shifted.value(k[0]);
    } else {
        return {};
    }
    *startsShortcut = function || mods.contains(QStringLiteral("Ctrl")) || mods.contains(QStringLiteral("Alt")) || mods.contains(QStringLiteral("Meta"));
    return joinChord(mods, key);
}

// one alternative ("ctrl+a>g") as a portable sequence; at most four chords, Qt's limit
static QString parseAlternative(const QString &alt, bool *startsShortcut)
{
    const QStringList chords = alt.split(QLatin1Char('>'));
    if (chords.size() > 4)
        return {};
    QStringList out;
    for (int i = 0; i < chords.size(); ++i) {
        bool starts = false;
        const QString c = parseChord(chords[i], &starts);
        if (c.isEmpty())
            return {};
        if (i == 0)
            *startsShortcut = starts;
        out << c;
    }
    return out.join(QStringLiteral(", "));
}

QStringList parseChordToken(const QString &token, QString *error)
{
    QStringList out;
    for (const QString &alt : token.split(QLatin1Char('|'))) {
        bool starts = false;
        const QString seq = parseAlternative(alt, &starts);
        if (seq.isEmpty()) {
            *error = QStringLiteral("invalid chord '%1'").arg(token);
            return {};
        }
        if (!starts) {
            *error = QStringLiteral("chord '%1' needs a modifier on its first key").arg(alt);
            return {};
        }
        out << seq;
    }
    return out;
}

// a leading # (after whitespace, outside quotes) starts a comment
static QString stripComment(const QString &line)
{
    bool single = false, dbl = false, afterSpace = true;
    QString out;
    for (const QChar ch : line) {
        if (ch == QLatin1Char('"') && !single)
            dbl = !dbl;
        else if (ch == QLatin1Char('\'') && !dbl)
            single = !single;
        else if (ch == QLatin1Char('#') && !single && !dbl && afterSpace)
            break;
        out += ch;
        afterSpace = ch.isSpace();
    }
    return out.trimmed();
}

static QString firstToken(const QString &s)
{
    const qsizetype at = s.indexOf(QRegularExpression(QStringLiteral("\\s")));
    return at < 0 ? s : s.left(at);
}

static QString afterToken(const QString &s, const QString &token)
{
    return s.mid(token.size()).trimmed();
}

// `"<name>" [chord] [--repeat] [--error-hud [--error-position P] [--error-pane left|right]] [--] <shell...>`
static bool parseCommand(const QString &rest, int line, CustomCommand *out, QList<KeymapDiagnostic> *diags)
{
    const qsizetype close = rest.indexOf(QLatin1Char('"'), 1);
    if (!rest.startsWith(QLatin1Char('"')) || close < 0) {
        diags->append({line, QStringLiteral("command requires a quoted name")});
        return false;
    }
    CustomCommand c;
    c.line = line;
    c.name = rest.mid(1, close - 1);
    QString body = rest.mid(close + 1).trimmed();
    auto reject = [&](const QString &why) {
        diags->append({line, QStringLiteral("command '%1' %2").arg(c.name, why)});
        return false;
    };
    // a first token is a chord only when some alternative of it is bindable; a shell line like `[ -f x ]` stays shell
    const QString tok = firstToken(body);
    bool anyAlt = false;
    for (const QString &alt : tok.split(QLatin1Char('|'))) {
        bool starts = false;
        anyAlt |= !parseAlternative(alt, &starts).isEmpty() && starts;
    }
    if (!tok.startsWith(QLatin1String("--")) && anyAlt) {
        for (const QString &alt : tok.split(QLatin1Char('|'))) {
            bool starts = false;
            const QString seq = parseAlternative(alt, &starts);
            if (seq.isEmpty())
                return reject(QStringLiteral("shortcut '%1' has an invalid alternative; command skipped").arg(tok));
            if (!starts)
                diags->append({line, QStringLiteral("command '%1' shortcut '%2' must include a modifier; alternative skipped").arg(c.name, alt)});
            else
                c.keys << seq;
        }
        c.raw = tok;
        body = afterToken(body, tok);
    }
    QSet<QString> seen;
    while (!body.isEmpty()) {
        const QString opt = firstToken(body);
        if (opt == QLatin1String("--")) {
            body = afterToken(body, opt);
            break;
        }
        if (opt == QLatin1String("--repeat")) {
            if (c.repeat)
                return reject(QStringLiteral("repeats option '--repeat'"));
            c.repeat = true;
            body = afterToken(body, opt);
            continue;
        }
        if (!opt.startsWith(QLatin1String("--error-")))
            break;
        if (!QStringList{"--error-hud", "--error-position", "--error-pane"}.contains(opt))
            return reject(QStringLiteral("has unknown option '%1'").arg(opt));
        if (seen.contains(opt))
            return reject(QStringLiteral("repeats option '%1'").arg(opt));
        seen << opt;
        body = afterToken(body, opt);
        if (opt == QLatin1String("--error-hud")) {
            c.errorHud = true;
            continue;
        }
        const QString value = firstToken(body);
        body = afterToken(body, value);
        static const QHash<QString, QString> positions{{"top-left", "top-left"},       {"top-center", "top-center"},   {"top", "top-center"},
                                                       {"top-right", "top-right"},     {"center-left", "center-left"}, {"center", "center"},
                                                       {"center-right", "center-right"}, {"bottom-left", "bottom-left"}, {"bottom", "bottom-center"},
                                                       {"bottom-center", "bottom-center"}, {"bottom-right", "bottom-right"}};
        if (opt == QLatin1String("--error-position")) {
            if (!positions.contains(value))
                return reject(QStringLiteral("requires a valid HUD position after --error-position"));
            c.errorPosition = positions.value(value);
        } else {
            if (value != QLatin1String("left") && value != QLatin1String("right"))
                return reject(QStringLiteral("requires left or right after --error-pane"));
            c.errorPane = value;
        }
    }
    if (!c.errorHud && !seen.isEmpty())
        return reject(QStringLiteral("requires --error-hud for error placement options"));
    if (body.isEmpty())
        return reject(QStringLiteral("has no shell line"));
    c.command = body;
    *out = c;
    return true;
}

Keymap parseKeymap(const QString &text, const QMap<QString, QStringList> &defaults)
{
    Keymap km;
    struct MapLine {
        QString action, raw;
        QStringList keys;
        int line;
    };
    QList<MapLine> maps;
    QString t = text;
    t.replace(QStringLiteral("\r\n"), QStringLiteral("\n")).replace(QLatin1Char('\r'), QLatin1Char('\n'));
    const QStringList lines = t.split(QLatin1Char('\n'));
    for (int i = 0; i < lines.size(); ++i) {
        const int n = i + 1;
        const QString line = stripComment(lines[i]);
        if (line.isEmpty())
            continue;
        const QString verb = firstToken(line), rest = afterToken(line, verb);
        if (verb == QLatin1String("map")) {
            const QString chord = firstToken(rest);
            QString action = afterToken(rest, chord);
            if (firstToken(action) == QLatin1String("--repeat")) {
                action = afterToken(action, QStringLiteral("--repeat"));
                km.diagnostics.append({n, QStringLiteral("--repeat is not supported yet; binding kept without it")});
            }
            if (chord.isEmpty() || action.isEmpty()) {
                km.diagnostics.append({n, QStringLiteral("map requires a chord and an action")});
                continue;
            }
            QString error;
            const QStringList keys = parseChordToken(chord, &error);
            if (keys.isEmpty()) {
                km.diagnostics.append({n, error + QStringLiteral("; map skipped")});
            } else if (!defaults.contains(action)) {
                km.diagnostics.append({n, masterBuiltinActions().contains(action) ? QStringLiteral("action '%1' is not available in agterm-qt").arg(action)
                                                                                   : QStringLiteral("unknown action '%1'").arg(action)});
            } else {
                maps.append({action, chord, keys, n});
            }
        } else if (verb == QLatin1String("command")) {
            CustomCommand c;
            if (!parseCommand(rest, n, &c, &km.diagnostics))
                continue;
            bool dup = false;
            for (const auto &o : std::as_const(km.commands))
                dup |= o.name == c.name;
            if (dup)
                km.diagnostics.append({n, QStringLiteral("command '%1' is already defined; command skipped").arg(c.name)});
            else
                km.commands.append(c);
            if (c.repeat && !dup)
                km.diagnostics.append({n, QStringLiteral("command '%1': --repeat is not supported yet; binding kept without it").arg(c.name)});
        } else if (verb == QLatin1String("global-hotkey")) {
            km.diagnostics.append({n, QStringLiteral("global-hotkey summons the quick terminal, which agterm-qt does not have; line skipped")});
        } else {
            km.diagnostics.append({n, QStringLiteral("unknown verb '%1'").arg(verb)});
        }
    }

    // a later map line for the same action replaces the earlier one; the action loses its default either way
    for (auto it = defaults.begin(); it != defaults.end(); ++it) {
        QStringList keys;
        for (const QString &k : it.value())
            keys << normalizeSequence(k);
        km.bindings.insert(it.key(), keys);
    }
    QMap<QString, MapLine> last;
    for (const MapLine &m : std::as_const(maps))
        last.insert(m.action, m);
    for (const MapLine &m : std::as_const(last)) {
        km.bindings[m.action].clear();
        km.raw.insert(m.action, m.raw);
    }
    // owners: untouched defaults first, then map lines in file order, then commands
    QHash<QString, QString> owner;
    for (auto it = km.bindings.begin(); it != km.bindings.end(); ++it)
        for (const QString &k : it.value())
            owner.insert(k, it.key());
    auto prefixClash = [&owner](const QString &k) -> QString {
        // "Ctrl+A" and "Ctrl+A, G" cannot both fire: the shorter one would always win
        for (auto it = owner.begin(); it != owner.end(); ++it)
            if (it.key() != k && (it.key().startsWith(k + QStringLiteral(", ")) || k.startsWith(it.key() + QStringLiteral(", "))))
                return it.value();
        return {};
    };
    for (const MapLine &m : std::as_const(last))
        for (const QString &k : m.keys) {
            const QString clash = owner.contains(k) ? owner.value(k) : prefixClash(k);
            if (!clash.isEmpty() && clash != m.action) {
                km.diagnostics.append({m.line, QStringLiteral("chord '%1' conflicts with built-in '%2'; alternative skipped").arg(k, clash)});
                continue;
            }
            km.bindings[m.action] << k;
            owner.insert(k, m.action);
        }
    for (CustomCommand &c : km.commands) {
        QStringList kept;
        for (const QString &k : std::as_const(c.keys)) {
            const QString clash = owner.contains(k) ? owner.value(k) : prefixClash(k);
            if (!clash.isEmpty()) {
                km.diagnostics.append({c.line, QStringLiteral("custom command '%1' shortcut '%2' conflicts with %3; alternative skipped")
                                                   .arg(c.name, k, km.bindings.contains(clash) ? QStringLiteral("built-in '%1'").arg(clash)
                                                                                                : QStringLiteral("custom command '%1'").arg(clash))});
                continue;
            }
            kept << k;
            owner.insert(k, c.name);
        }
        c.keys = kept;
    }
    std::sort(km.diagnostics.begin(), km.diagnostics.end(), [](const auto &a, const auto &b) { return a.line < b.line; });
    return km;
}

// a portable sequence back in the file's grammar, for the starter's default column
static QString kittySpelling(const QString &seq)
{
    QStringList chords;
    for (QString c : seq.split(QStringLiteral(", "))) {
        c.replace(QStringLiteral("Ctrl+"), QStringLiteral("ctrl+")).replace(QStringLiteral("Alt+"), QStringLiteral("alt+"));
        c.replace(QStringLiteral("Shift+"), QStringLiteral("shift+")).replace(QStringLiteral("Meta+"), QStringLiteral("super+"));
        chords << c.toLower();
    }
    return chords.join(QLatin1Char('>'));
}

QString starterKeymap(const QMap<QString, QStringList> &defaults)
{
    QString actions;
    for (auto it = defaults.begin(); it != defaults.end(); ++it) {
        QStringList keys;
        for (const QString &k : it.value())
            keys << kittySpelling(normalizeSequence(k));
        actions += QStringLiteral("#   %1%2\n").arg(it.key(), -28).arg(keys.isEmpty() ? QStringLiteral("(no default)") : keys.join(QLatin1Char('|')));
    }
    QString tokens;
    for (const QString &t : commandTokens())
        tokens += QStringLiteral("#   {%1}\n").arg(t);
    return QStringLiteral(
               "# agterm-qt keymap: a kitty-flavored config for rebinding built-in shortcuts and defining\n"
               "# custom shell commands. Edit this file and run File > Reload Keymap (or `agtermctl keymap\n"
               "# reload`) to apply. Blank lines and lines starting with `#` are ignored. A line that is\n"
               "# rejected or skipped is reported in Settings > Key Mapping and by `agtermctl keymap list`.\n"
               "#\n"
               "#   map <chord> <action>\n"
               "#       Rebind a built-in action. Mods: ctrl, shift, alt (opt), super, joined by `+`, e.g.\n"
               "#       `ctrl+alt+l`. agterm's macOS words also work: cmd alone means ctrl+shift, cmd with any\n"
               "#       other modifier means ctrl+alt+shift, opt means alt. Keys: a character, tab, space, return,\n"
               "#       delete, escape, left, right, up, down, home, end, pageup, pagedown, f1-f20. A Shift-typed\n"
               "#       symbol is shift+<base key> (shift+/ for ?). Alternatives join with `|` (no spaces), and\n"
               "#       a leader sequence with `>` (ctrl+a>s). Every chord needs ctrl, alt or super on its first\n"
               "#       key, or a function key. A mapped action loses its default.\n"
               "#\n"
               "#           map ctrl+alt+l       toggle_split\n"
               "#           map ctrl+shift+t|ctrl+a>t  new_session\n"
               "#\n"
               "#   command \"<name>\" [chord] [--error-hud] <shell...>\n"
               "#       A custom command, listed in the custom-commands palette (ctrl+alt+o) and the action\n"
               "#       palette. The rest of the line runs through `/bin/sh -c`, detached with no terminal, in\n"
               "#       the session's directory, so it suits launches and scripts, not interactive programs.\n"
               "#       A non-zero exit posts a notification; --error-hud adds the command's stderr to it.\n"
               "#\n"
               "#           command \"Open in Kate\"  ctrl+alt+k  kate \"$AGT_SESSION_PWD\"\n"
               "#           command \"Lazygit\"       ctrl+a>g    agtermctl session new --parent \"$AGT_SESSION_ID\" --command lazygit --socket \"$AGT_SOCKET\"\n"
               "#           command \"Deploy\"                    ./deploy.sh\n"
               "#\n"
               "# Built-in actions (raw name, shipped default):\n"
               "#\n%1"
               "#\n"
               "# Custom-command tokens (expanded raw in the shell line and exported as $AGT_X variables;\n"
               "# prefer the quoted variable for text you do not control, e.g. \"$AGT_SELECTION\"):\n"
               "#\n%2"
               "#\n"
               "# Uncomment and edit a line below to start.\n"
               "# map ctrl+alt+l toggle_split\n")
        .arg(actions, tokens);
}

const QStringList &commandTokens()
{
    static const QStringList tokens{"AGT_SESSION_ID", "AGT_SESSION_NAME", "AGT_SESSION_PWD", "AGT_SESSION_HOST", "AGT_WORKSPACE_ID", "AGT_WORKSPACE_NAME",
                                    "AGT_WINDOW_ID", "AGT_WINDOW_NAME", "AGT_PANE", "AGT_PANE_ID", "AGT_SELECTION", "AGT_SOCKET"};
    return tokens;
}

QString expandTokens(QString command, const QHash<QString, QString> &ctx)
{
    for (const QString &t : commandTokens())
        command.replace(QLatin1Char('{') + t + QLatin1Char('}'), ctx.value(t));
    return command;
}

const QStringList &eventKinds()
{
    static const QStringList kinds{"status",       "notify",      "session.created", "session.closed", "session.selected", "tree.changed",
                                   "pane.split",   "pane.scratch", "pane.focused",   "remote.opened",  "remote.closed",    "app.launched", "message"};
    return kinds;
}

QList<HookLine> parseHooks(const QString &text, QList<KeymapDiagnostic> *diagnostics)
{
    QList<HookLine> out;
    QSet<QString> seen;
    QString t = text;
    t.replace(QStringLiteral("\r\n"), QStringLiteral("\n")).replace(QLatin1Char('\r'), QLatin1Char('\n'));
    const QStringList lines = t.split(QLatin1Char('\n'));
    for (int i = 0; i < lines.size(); ++i) {
        const int n = i + 1;
        const QString line = lines[i].trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const QString verb = firstToken(line);
        if (verb != QLatin1String("on")) {
            diagnostics->append({n, QStringLiteral("unknown verb '%1'").arg(verb)});
            continue;
        }
        const QString rest = afterToken(line, verb), kind = firstToken(rest), command = afterToken(rest, kind);
        if (kind.isEmpty()) {
            diagnostics->append({n, QStringLiteral("on requires an event kind")});
        } else if (!eventKinds().contains(kind)) {
            diagnostics->append({n, QStringLiteral("unknown event kind '%1'").arg(kind)});
        } else if (command.isEmpty()) {
            diagnostics->append({n, QStringLiteral("hook for '%1' has no shell line").arg(kind)});
        } else if (seen.contains(kind + QLatin1Char(' ') + command)) {
            diagnostics->append({n, QStringLiteral("hook 'on %1 %2' is already defined; hook skipped").arg(kind, command)});
        } else {
            seen << kind + QLatin1Char(' ') + command;
            out.append({kind, command, n});
        }
    }
    return out;
}

QString starterHooks()
{
    return QStringLiteral(
               "# agterm-qt hooks: run a shell line when a control event fires. Edit this file and run\n"
               "# File > Reload Hooks (or `agtermctl hooks reload`) to apply. Blank lines and lines starting\n"
               "# with `#` are ignored.\n"
               "#\n"
               "#   on <kind> <shell...>\n"
               "#\n"
               "# Kinds: %1.\n"
               "# (pane.scratch, pane.focused, remote.* and message never fire in agterm-qt.)\n"
               "# Several lines per kind run independently; an identical kind+command line is skipped with a\n"
               "# diagnostic. Everything after the kind is passed to `/bin/sh -c` untouched, detached with no\n"
               "# terminal, one process per line at a time; further events for a busy line queue in order\n"
               "# (256 pending, oldest dropped).\n"
               "#\n"
               "# The script gets the event as one JSON object on stdin and these variables: AGT_EVENT_KIND,\n"
               "# AGT_EVENT_STATUS, AGT_EVENT_HOST, AGT_SESSION_ID, AGT_WORKSPACE_ID, AGT_WINDOW_ID, AGT_SOCKET.\n"
               "# Pass `--socket \"$AGT_SOCKET\"` to any agtermctl call. A hook whose command emits another event\n"
               "# of its own kind triggers itself again.\n"
               "#\n"
               "# Examples:\n"
               "#\n"
               "#   on status           ~/.config/agterm-qt/hooks/status.sh\n"
               "#   on session.closed   echo \"$(date +%T) closed $AGT_SESSION_ID\" >> ~/.local/state/agterm-qt/sessions.log\n"
               "#   on tree.changed     ~/.config/agterm-qt/hooks/sync-outline.sh\n"
               "#\n"
               "# Uncomment and edit a line below to start.\n"
               "# on status [ \"$AGT_EVENT_STATUS\" = blocked ] || exit 0; notify-send \"$AGT_SESSION_ID needs input\"\n")
        .arg(eventKinds().join(QStringLiteral(", ")));
}
