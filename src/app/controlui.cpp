// Control commands that drive widgets: the sidebar, pane selection/clipboard/search, zoom, the pick palette and asks.
#include "mainwindow.h"

#include "hooks.h"
#include "konsoleprivate.h"
#include "palette.h"
#include "store.h"

#include <KActionCollection>
#include <KParts/ReadOnlyPart>

#include <QApplication>
#include <QButtonGroup>
#include <QCheckBox>
#include <QDesktopServices>
#include <QDialog>
#include <QFileInfo>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QRadioButton>
#include <QSplitter>
#include <QUrl>
#include <QUuid>
#include <QVBoxLayout>

// results outlive their window and are polled by id from any window: app-wide, the newest kept
static QHash<QString, QJsonObject> s_picks, s_asks;
static QStringList s_pickOrder, s_askOrder;

static void retain(QHash<QString, QJsonObject> &results, QStringList &order, const QString &id, const QJsonObject &result, int keep)
{
    results.insert(id, result);
    order.removeAll(id);
    order << id;
    while (order.size() > keep)
        results.remove(order.takeFirst());
}

KParts::ReadOnlyPart *MainWindow::panePart(const QString &id, const QString &pane) const
{
    const Panes p = m_panes.value(id);
    return pane == QLatin1String("right") ? p.right : p.main;
}

QStringList MainWindow::paneIds(const QString &sessionId) const
{
    QStringList out;
    const Panes p = m_panes.value(sessionId);
    for (KParts::ReadOnlyPart *part : {p.main, p.right})
        if (part && !part->property("agtermPaneId").toString().isEmpty())
            out << part->property("agtermPaneId").toString();
    return out;
}

QString MainWindow::text(const QString &sessionId, const QString &pane, bool scrollback, QString *error)
{
    KParts::ReadOnlyPart *part = panePart(sessionId, pane);
    if (!part)
        return *error = QStringLiteral("session not realized"), QString();
    prime(m_panes.value(sessionId).view);
    QObject *s = sessionOf(part);
    QString out;
    bool ok = false;
    if (scrollback && s)
        out = KonsolePrivate::scrollback(s, terminalDisplay(part), &ok);
    if (!ok && (!s || !QMetaObject::invokeMethod(s, "getAllDisplayedText", Q_RETURN_ARG(QString, out), Q_ARG(bool, true))))
        *error = QStringLiteral("failed to read surface buffer");
    return out;
}

void MainWindow::emitEvent(const QString &kind, const QString &sessionId, const QJsonObject &payload)
{
    const Workspace *w = m_store.workspaceOf(sessionId);
    m_events->emitEvent(kind, w ? w->id : QString(), sessionId, payload);
}

QJsonObject MainWindow::controlExtras(const QString &id) const
{
    QJsonObject out;
    if (const Session *s = const_cast<Store &>(m_store).session(id); s && s->hasSplit)
        out.insert("splitFocused", m_splitFocused.value(id));
    for (auto it = m_asks.begin(); it != m_asks.end(); ++it)
        if (it->session == id && !it->gui) {
            QJsonObject ask{{"id", it.key()}};
            if (!it->pane.isEmpty())
                ask.insert("pane", it->pane);
            out.insert("ask", ask);
        }
    return out;
}

QJsonObject MainWindow::controlChrome() const
{
    QJsonObject out{{"sidebarWidth", m_split->sizes().value(0)}};
    if (m_zoomed)
        out.insert("zoomedSurface", m_zoomSurface);
    if (!m_pickId.isEmpty())
        out.insert("pickPending", m_pickId);
    for (auto it = m_asks.begin(); it != m_asks.end(); ++it)
        if (it->gui)
            out.insert("askPending", it.key());
    return out;
}

// edit actions live on Konsole's per-view controller, not the part's own collection: find the one tied to this part
static bool trigger(KParts::ReadOnlyPart *part, const char *action)
{
    QAction *a = part ? part->actionCollection()->action(QLatin1String(action)) : nullptr;
    for (KActionCollection *col : KActionCollection::allCollections()) {
        bool mine = false;
        for (QObject *o = col; o && !mine; o = o->parent())
            mine = o == part || o == part->widget();
        for (QWidget *w : col->associatedWidgets())
            mine |= part->widget()->isAncestorOf(w);
        if (!a && mine)
            a = col->action(QLatin1String(action));
    }
    if (a)
        a->trigger();
    return a;
}

bool MainWindow::pickCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error)
{
    if (cmd == QLatin1String("pick.open")) {
        if (!m_pickId.isEmpty())
            return *error = QStringLiteral("pick already pending"), false;
        for (const Ask &a : std::as_const(m_asks))
            if (a.gui)
                return *error = QStringLiteral("ask already pending"), false;
        const QString pick = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const QJsonArray items = args.value("items").toArray();
        QList<Palette::Item> rows;
        int current = -1;
        for (int i = 0; i < items.size(); ++i) {
            const QJsonObject it = items[i].toObject();
            rows.append({it.value("label").toString(), it.value("subtitle").toString(), [this, pick, it, i] {
                             m_pickId.clear();
                             retain(s_picks, s_pickOrder, pick, {{"result", "picked"}, {"id", it.value("id")}, {"label", it.value("label")}, {"index", i}}, 8);
                         }});
            if (it.value("id").toString() == args.value("selection").toString())
                current = i;
        }
        m_pickId = pick;
        retain(s_picks, s_pickOrder, pick, {{"result", "pending"}}, 8);
        m_palette->open(args.value("prompt").toString(), rows, false, [this, pick] {
            m_pickId.clear();
            retain(s_picks, s_pickOrder, pick, {{"result", "cancelled"}}, 8);
        }, current < 0 ? 0 : current);
        if (args.value("allowCustom").toBool())
            m_palette->custom = [this, pick](const QString &query) {
                m_pickId.clear();
                retain(s_picks, s_pickOrder, pick, {{"result", "custom"}, {"query", query}}, 8);
            };
        if (args.contains("query"))
            m_palette->setQuery(args.value("query").toString());
        if (args.value("follow").toBool())
            raise(), activateWindow();
        *result = {{"id", pick}};
        return true;
    }
    if (!s_picks.contains(id))
        return *error = QStringLiteral("unknown pick: %1").arg(id), false;
    if (cmd == QLatin1String("pick.cancel")) {
        if (m_pickId == id)
            m_palette->hide(), m_pickId.clear(), retain(s_picks, s_pickOrder, id, {{"result", "cancelled"}}, 8);
        return true;
    }
    *result = {{"pick", s_picks.value(id)}};
    return true;
}

void MainWindow::finishAsk(const QString &id, const QJsonObject &outcome)
{
    const Ask ask = m_asks.take(id);
    retain(s_asks, s_askOrder, id, outcome, 32);
    if (ask.dialog)
        ask.dialog->deleteLater();
    syncChrome();
}

bool MainWindow::askCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error)
{
    if (cmd != QLatin1String("ask.open")) {
        const QString ask = args.value("ask").toString();
        if (!s_asks.contains(ask))
            return *error = QStringLiteral("unknown ask: %1").arg(ask), false;
        // shortcut: only the window that opened the ask closes its dialog; library routes an ask id to the front window
        if (cmd == QLatin1String("ask.cancel") && m_asks.contains(ask))
            finishAsk(ask, {{"result", "cancelled"}});
        if (cmd == QLatin1String("ask.result"))
            *result = {{"ask", s_asks.value(ask)}};
        return true;
    }
    const bool gui = args.value("style").toString() == QLatin1String("gui");
    for (auto it = m_asks.begin(); it != m_asks.end(); ++it)
        if ((gui && it->gui) || (!gui && !it->gui && it->session == id))
            return *error = QStringLiteral("ask already pending"), false;
    if (gui && !m_pickId.isEmpty())
        return *error = QStringLiteral("pick already pending"), false;
    const QString pane = args.value("pane").toString();
    const QString paneRole = pane.isEmpty() ? QString() : QStringList{"right", "bottom", "split"}.contains(pane) ? QStringLiteral("right") : QStringLiteral("left");
    if (paneRole == QLatin1String("right") && !m_store.session(id)->hasSplit)
        return *error = QStringLiteral("session has no split pane"), false;

    const QString askId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    auto *dlg = new QDialog(this);
    dlg->setObjectName(QStringLiteral("ask"));
    dlg->setWindowTitle(args.value("title").toString());
    auto *layout = new QVBoxLayout(dlg);
    auto *title = new QLabel(args.value("title").toString());
    QFont tf = title->font();
    tf.setWeight(QFont::DemiBold);
    title->setFont(tf);
    title->setWordWrap(true);
    layout->addWidget(title);
    if (args.contains("message")) {
        auto *message = new QLabel(args.value("message").toString());
        message->setWordWrap(true);
        layout->addWidget(message);
    }
    QLineEdit *line = nullptr, *other = nullptr;
    QPlainTextEdit *multi = nullptr;
    QList<QAbstractButton *> choiceBoxes;
    QAbstractButton *otherBox = nullptr;
    if (args.value("input").toString() == QLatin1String("line")) {
        layout->addWidget(line = new QLineEdit(args.value("value").toString()));
        line->setPlaceholderText(args.value("placeholder").toString());
    } else if (args.value("input").toString() == QLatin1String("multiline")) {
        layout->addWidget(multi = new QPlainTextEdit(args.value("value").toString()));
        multi->setPlaceholderText(args.value("placeholder").toString());
    } else if (args.contains("choices")) {
        const bool multiple = args.value("multiple").toBool();
        auto *group = new QButtonGroup(dlg);
        group->setExclusive(!multiple);
        QStringList checked;
        for (const auto &v : args.value("checked").toArray())
            checked << v.toString();
        auto box = [&](const QString &label, const QString &choiceId) {
            QAbstractButton *b = multiple ? static_cast<QAbstractButton *>(new QCheckBox(label)) : new QRadioButton(label);
            b->setProperty("choice", choiceId);
            b->setChecked(checked.contains(choiceId));
            group->addButton(b);
            layout->addWidget(b);
            return b;
        };
        for (const auto &v : args.value("choices").toArray()) {
            const QJsonObject c = v.toObject();
            choiceBoxes << box(c.value("label").toString(), c.value("id").toString());
            if (c.contains("subtitle")) {
                auto *sub = new QLabel(c.value("subtitle").toString());
                sub->setForegroundRole(QPalette::PlaceholderText);
                sub->setContentsMargins(24, 0, 0, 0);
                layout->addWidget(sub);
            }
        }
        if (args.contains("other")) {
            otherBox = box(tr("Other"), {});
            layout->addWidget(other = new QLineEdit);
            other->setPlaceholderText(args.value("other").toString());
            connect(other, &QLineEdit::textEdited, otherBox, [otherBox] { otherBox->setChecked(true); });
        }
    }
    auto *row = new QHBoxLayout;
    const QString align = args.value("align").toString(QStringLiteral("right"));
    if (align != QLatin1String("left"))
        row->addStretch(1);
    const QJsonArray buttons = args.value("buttons").toArray();
    for (int i = 0; i < buttons.size(); ++i) {
        const QJsonObject b = buttons[i].toObject();
        auto *button = new QPushButton(b.value("label").toString());
        const QString key = b.value("hotkey").toString().toLower();
        if (!key.isEmpty())
            button->setShortcut(QKeySequence(key)); // master's bare-letter hotkeys
        button->setAutoDefault(false);
        button->setDefault(b.value("id") == args.value("defaultButton"));
        if (b.value("id") == args.value("destructiveButton"))
            button->setStyleSheet(QStringLiteral("color: palette(link-visited)"));
        connect(button, &QPushButton::clicked, this, [=, this] {
            QJsonObject outcome{{"result", "answered"}, {"id", b.value("id")}, {"label", b.value("label")}, {"index", i}};
            if (line || multi)
                outcome.insert("text", line ? line->text() : multi->toPlainText());
            if (!choiceBoxes.isEmpty()) {
                QJsonArray selected;
                for (QAbstractButton *c : choiceBoxes)
                    if (c->isChecked())
                        selected << c->property("choice").toString();
                outcome.insert("selected", selected);
                if (otherBox && otherBox->isChecked())
                    outcome.insert("text", other->text());
            }
            finishAsk(askId, outcome);
        });
        row->addWidget(button);
    }
    if (align == QLatin1String("center") || align == QLatin1String("left"))
        row->addStretch(1);
    layout->addLayout(row);
    connect(dlg, &QDialog::rejected, this, [this, askId] {
        if (m_asks.contains(askId))
            finishAsk(askId, {{"result", "escaped"}});
    });
    if (args.contains("width"))
        dlg->resize(width() * args.value("width").toInt() / 100, dlg->sizeHint().height());
    m_asks.insert(askId, {dlg, gui ? QString() : id, paneRole, gui});
    retain(s_asks, s_askOrder, askId, {{"result", "pending"}}, 32);
    // shortcut: a terminal-style ask is a non-modal dialog over the window, not drawn inside the pane; it shows at once
    // even for an unselected session
    gui ? dlg->open() : dlg->show();
    if (args.value("follow").toBool() && !id.isEmpty())
        m_store.select(id);
    *result = {{"id", askId}};
    if (!paneRole.isEmpty())
        result->insert("pane", paneRole);
    syncChrome();
    return true;
}

bool MainWindow::uiCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error, bool *handled)
{
    *handled = true;
    if (cmd == QLatin1String("sidebar")) {
        const QString mode = args.value("mode").toString(QStringLiteral("toggle"));
        if (mode != QLatin1String("show") && mode != QLatin1String("hide") && mode != QLatin1String("toggle"))
            return *error = QStringLiteral("invalid sidebar mode: %1").arg(mode), false;
        m_sidebarAction->setChecked(mode == QLatin1String("toggle") ? !m_sidebarAction->isChecked() : mode == QLatin1String("show"));
        m_sidebarPanel->setVisible(m_sidebarAction->isChecked());
        m_saveTimer.start();
        *result = {{"sidebarVisible", m_sidebarAction->isChecked()}};
        return true;
    }
    if (cmd == QLatin1String("sidebar.width")) {
        const double w = args.value("sidebarWidth").toDouble(-1);
        if (!args.value("sidebarWidth").isDouble() || !std::isfinite(w))
            return *error = QStringLiteral("sidebar.width requires a width in points"), false;
        const int px = qRound(qBound(160.0, w, 560.0));
        QList<int> sizes = m_split->sizes();
        sizes[sizes.size() - 1] += sizes[0] - px;
        sizes[0] = px;
        m_split->setSizes(sizes);
        m_saveTimer.start();
        *result = {{"sidebarWidth", qBound(160.0, w, 560.0)}};
        return true;
    }
    if (cmd.startsWith(QLatin1String("pick.")))
        return pickCommand(cmd, id, args, result, error);
    if (cmd.startsWith(QLatin1String("ask.")))
        return askCommand(cmd, id, cmd == QLatin1String("ask.open") ? args : QJsonObject{{"ask", id}}, result, error);
    if (cmd == QLatin1String("surface.zoom")) {
        const QString mode = args.value("mode").toString(QStringLiteral("toggle"));
        if (mode != QLatin1String("show") && mode != QLatin1String("hide") && mode != QLatin1String("toggle"))
            return *error = QStringLiteral("invalid surface zoom mode: %1").arg(mode), false;
        QString surface = id;
        if (surface.isEmpty() || surface == QLatin1String("active")) {
            if (m_zoomed || mode == QLatin1String("hide")) {
                if (m_zoomed && mode != QLatin1String("show"))
                    toggleZoom();
                *result = m_zoomed ? QJsonObject{{"id", m_zoomSurface}} : QJsonObject{};
                return true;
            }
            if (!m_store.session(m_store.selected))
                return *error = QStringLiteral("no active surface"), false;
            const Panes p = m_panes.value(m_store.selected);
            const bool right = p.right && p.right->widget()->isVisible() && m_splitFocused.value(m_store.selected);
            surface = QStringLiteral("surface:%1:%2").arg(m_store.selected, right ? QStringLiteral("right") : QStringLiteral("left"));
        } else if (surface == QLatin1String("quick")) {
            return *error = QStringLiteral("surface not available: quick"), false;
        }
        const QStringList parts = surface.split(QLatin1Char(':'));
        if (parts.size() != 3 || parts[0] != QLatin1String("surface"))
            return *error = QStringLiteral("invalid surface: %1").arg(surface), false;
        QString e;
        const QString sid = m_store.resolveSession(parts[1], &e);
        KParts::ReadOnlyPart *part = sid.isEmpty() ? nullptr : panePart(sid, parts[2]);
        if (sid.isEmpty() || !QStringList{"left", "right"}.contains(parts[2]) || !part)
            return *error = QStringLiteral("surface not available: %1").arg(surface), false;
        surface = QStringLiteral("surface:%1:%2").arg(sid, parts[2]);
        const bool on = mode == QLatin1String("show") || (mode == QLatin1String("toggle") && !(m_zoomed && m_zoomSurface == surface));
        if (on) {
            m_store.select(sid);
            part->widget()->setFocus();
        }
        if (on != m_zoomed)
            toggleZoom();
        m_zoomSurface = on ? surface : QString();
        *result = {{"id", surface}};
        return true;
    }
    if (!QStringList{"session.focus", "session.copy", "session.paste", "session.selectall", "session.search", "session.reveal"}.contains(cmd)) {
        *handled = false;
        return false;
    }
    Session *s = m_store.session(id);
    if (cmd == QLatin1String("session.reveal")) {
        const QString live = liveCwd(id), dir = QFileInfo(live).isDir() ? live : s->cwd;
        if (!QFileInfo(dir).isDir())
            return *error = QStringLiteral("session cwd is not an existing directory"), false;
        if (QGuiApplication::platformName() != QLatin1String("offscreen")) // tests and smoke have no file manager to show
            QDesktopServices::openUrl(QUrl::fromLocalFile(dir));
        return true;
    }
    if (cmd == QLatin1String("session.focus")) {
        if (!s->hasSplit)
            return *error = QStringLiteral("session has no split"), false;
        const QString pane = args.value("pane").toString(QStringLiteral("other"));
        bool right;
        if (QStringList{"left", "top", "primary"}.contains(pane))
            right = false;
        else if (QStringList{"right", "bottom", "split"}.contains(pane))
            right = true;
        else if (pane == QLatin1String("other") || pane == QLatin1String("toggle"))
            right = !m_splitFocused.value(id);
        else
            return *error = QStringLiteral("invalid pane: %1").arg(pane), false;
        m_splitFocused.insert(id, right);
        if (KParts::ReadOnlyPart *part = panePart(id, right ? QStringLiteral("right") : QStringLiteral("left")); part && part->widget()->isVisible())
            part->widget()->setFocus();
        return true;
    }
    QString pane = args.value("pane").toString(QStringLiteral("left"));
    if (!QStringList{"left", "top", "primary", "right", "bottom", "split"}.contains(pane))
        return *error = QStringLiteral("--pane must be left, right, or scratch"), false;
    pane = QStringList{"right", "bottom", "split"}.contains(pane) ? QStringLiteral("right") : QStringLiteral("left");
    if (pane == QLatin1String("right") && !s->hasSplit)
        return *error = QStringLiteral("session has no split pane"), false;
    KParts::ReadOnlyPart *part = panePart(id, pane);
    QObject *session = part ? sessionOf(part) : nullptr;
    if (!part || !session)
        return *error = QStringLiteral("session not realized"), false;
    if (cmd == QLatin1String("session.copy")) {
        const QString text = KonsolePrivate::selectedText(session);
        if (text.isEmpty())
            return *error = QStringLiteral("no selection"), false;
        *result = {{"text", text}};
        return true;
    }
    if (cmd == QLatin1String("session.paste") || cmd == QLatin1String("session.selectall"))
        return trigger(part, cmd == QLatin1String("session.paste") ? "edit_paste" : "select-all") || (*error = QStringLiteral("session not realized"), false);
    // session.search: Konsole's own search bar; the count comes from the pane's history, case-insensitively
    const QString to = args.value("to").toString();
    QLineEdit *field = nullptr;
    for (QWidget *w : part->widget()->findChildren<QWidget *>())
        if (w->inherits("Konsole::IncrementalSearchBar"))
            field = w->findChild<QLineEdit *>();
    if (to == QLatin1String("close")) {
        if (field && field->parentWidget()->isVisible()) {
            QKeyEvent escape(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
            QApplication::sendEvent(field, &escape);
        }
        return true;
    }
    m_store.select(id);
    if (!field || !field->isVisible()) {
        trigger(part, "edit_find");
        for (QWidget *w : part->widget()->findChildren<QWidget *>())
            if (w->inherits("Konsole::IncrementalSearchBar"))
                field = w->findChild<QLineEdit *>();
    }
    if (!field)
        return *error = QStringLiteral("session not realized"), false;
    if (args.contains("text"))
        field->setText(args.value("text").toString());
    if (to == QLatin1String("next") || to == QLatin1String("prev"))
        trigger(part, to == QLatin1String("next") ? "edit_find_next" : "edit_find_prev");
    const QString needle = field->text();
    if (needle.isEmpty())
        return true;
    bool ok = false;
    const int count = int(KonsolePrivate::scrollback(session, terminalDisplay(part), &ok).count(needle, Qt::CaseInsensitive));
    result->insert("count", count);
    result->insert("text", count ? QStringLiteral("%1 matches").arg(count) : QStringLiteral("no matches"));
    return true;
}
