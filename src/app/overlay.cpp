// Overlays (a program in a temporary terminal over a session or one pane) and the passive HUD.
#include "mainwindow.h"
#include "store.h"

#include <KParts/ReadOnlyPart>
#include <kde_terminal_interface.h>

#include <QDir>
#include <QFile>
#include <QFrame>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QStackedWidget>
#include <QStatusBar>
#include <QUuid>
#include <QVBoxLayout>

static QString slotKey(const QString &id, const QString &pane)
{
    return id + QLatin1Char('|') + (pane.isEmpty() ? QStringLiteral("session") : pane);
}

// A message panel that takes no input: clicks fall through to the terminal and focus never moves.
class Hud : public QFrame
{
public:
    QJsonObject spec;
    QTimer hideTimer;

    explicit Hud(QWidget *parent)
        : QFrame(parent)
    {
        setObjectName(QStringLiteral("agtermHud"));
        setAttribute(Qt::WA_TransparentForMouseEvents);
        setFocusPolicy(Qt::NoFocus);
        auto *row = new QHBoxLayout(this);
        row->setContentsMargins(14, 10, 14, 10);
        row->setSpacing(10);
        row->addWidget(m_spin);
        auto *col = new QVBoxLayout;
        col->setSpacing(2);
        col->addWidget(m_message);
        col->addWidget(m_detail);
        row->addLayout(col, 1);
        for (QLabel *l : {m_spin, m_message, m_detail}) {
            l->setFocusPolicy(Qt::NoFocus);
            l->setAttribute(Qt::WA_TransparentForMouseEvents);
        }
        m_message->setWordWrap(true);
        m_detail->setWordWrap(true);
        m_detail->setForegroundRole(QPalette::PlaceholderText);
        m_spinTimer.setInterval(100);
        connect(&m_spinTimer, &QTimer::timeout, this, [this] {
            m_frame = (m_frame + 1) % m_frames.size();
            m_spin->setText(m_frames.value(m_frame));
        });
        hideTimer.setSingleShot(true);
    }

    void apply(const QJsonObject &s)
    {
        spec = s;
        const bool markdown = s.value("markdown").toBool();
        m_message->setTextFormat(markdown ? Qt::MarkdownText : Qt::PlainText);
        m_message->setText(s.value("message").toString());
        m_detail->setText(s.value("detail").toString());
        m_detail->setVisible(!m_detail->text().isEmpty());
        static const QHash<QString, QStringList> frames{
            {"bar", {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃", "▂"}},
            {"braille", {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}},
            {"circle", {"◐", "◓", "◑", "◒"}},
            {"blocks", {"▖", "▘", "▝", "▗"}},
            {"dot", {"⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"}}};
        m_frames = frames.value(s.value("spinner").toString());
        m_spin->setVisible(!m_frames.isEmpty());
        m_frames.isEmpty() ? m_spinTimer.stop() : m_spinTimer.start();
        if (s.contains("fontSize")) {
            QFont f = m_message->font();
            f.setPointSizeF(s.value("fontSize").toDouble());
            m_message->setFont(f);
            m_spin->setFont(f);
        }
        const QString bg = s.value("color").toString(palette().color(QPalette::Window).name());
        const QString ink = s.value("textColor").toString();
        const bool framed = s.value("frame").toBool(true);
        setStyleSheet(QStringLiteral("QFrame#agtermHud{background:%1;%2}%3")
                          .arg(bg, framed ? QStringLiteral("border:1px solid palette(mid);border-radius:8px;") : QString(),
                               ink.isEmpty() ? QString() : QStringLiteral("QLabel{color:%1}").arg(ink)));
        const int secs = s.value("hideAfter").toInt();
        secs > 0 ? hideTimer.start(secs * 1000) : hideTimer.stop(); // every open/update restarts the full interval
    }

    void place(const QRect &target)
    {
        const QString pos = spec.value("position").toString(QStringLiteral("center"));
        const bool sticky = spec.value("sticky").toBool() && pos != QLatin1String("center");
        const int margin = sticky ? 0 : 16;
        const int maxW = int(target.width() * (sticky ? 1.0 : 0.8));
        int w = 0;
        if (spec.contains("sizePercent")) {
            w = target.width() * spec.value("sizePercent").toInt() / 100;
        } else {
            // the longest line decides; markdown wraps at 60 columns while the width is auto
            const QFontMetrics fm(m_message->font());
            int natural = 0;
            for (const QString &line : m_message->text().split(QLatin1Char('\n')))
                natural = qMax(natural, fm.horizontalAdvance(line));
            if (spec.value("markdown").toBool())
                natural = qMin(natural, fm.averageCharWidth() * 60);
            natural = qMax(natural, QFontMetrics(m_detail->font()).horizontalAdvance(m_detail->text()));
            const QMargins m = layout()->contentsMargins();
            w = natural + m.left() + m.right() + (m_spin->isVisible() ? m_spin->sizeHint().width() + layout()->spacing() : 0) + 4;
            w = qBound(target.width() / 10, w, maxW);
        }
        const int h = qMin(layout()->totalHeightForWidth(w), int(target.height() * 0.8));
        const int x = pos.endsWith(QLatin1String("left"))    ? target.left() + margin
                      : pos.endsWith(QLatin1String("right")) ? target.right() - margin - w + 1
                                                             : target.center().x() - w / 2;
        const int y = pos.startsWith(QLatin1String("top"))      ? target.top() + margin
                      : pos.startsWith(QLatin1String("bottom")) ? target.bottom() - margin - h + 1
                                                                : target.center().y() - h / 2;
        setGeometry(x, y, w, h);
        raise();
    }

private:
    QLabel *m_spin = new QLabel, *m_message = new QLabel, *m_detail = new QLabel;
    QStringList m_frames;
    int m_frame = 0;
    QTimer m_spinTimer;
};

QWidget *MainWindow::paneWidget(const QString &id, const QString &pane) const
{
    const Panes p = m_panes.value(id);
    KParts::ReadOnlyPart *part = pane == QLatin1String("right") ? p.right : p.main;
    return part ? part->widget() : nullptr;
}

QRect MainWindow::overlayTarget(const QString &id, const QString &pane) const
{
    const Panes p = m_panes.value(id);
    QWidget *w = pane.isEmpty() ? nullptr : paneWidget(id, pane);
    return w ? QRect(w->mapTo(p.view, QPoint(0, 0)), w->size()) : p.view->rect();
}

void MainWindow::layoutOverlays(const QString &id)
{
    for (const QString &pane : {QString(), QStringLiteral("left"), QStringLiteral("right")}) {
        const Overlay ov = m_overlays.value(slotKey(id, pane));
        if (!ov.frame)
            continue;
        const QRect t = overlayTarget(id, pane);
        if (ov.sizePercent <= 0) {
            ov.frame->setGeometry(t);
        } else {
            // a point axis overrides the percent and is capped at 80% of the session
            const int w = ov.width > 0 ? qMin(int(ov.width), int(t.width() * 0.8)) : t.width() * ov.sizePercent / 100;
            const int h = ov.height > 0 ? qMin(int(ov.height), int(t.height() * 0.8)) : t.height() * ov.sizePercent / 100;
            ov.frame->setGeometry(QRect(0, 0, w, h).translated(t.center() - QPoint(w / 2, h / 2)));
        }
        ov.frame->raise();
    }
    if (auto *hud = static_cast<Hud *>(m_huds.value(id).data()))
        hud->place(overlayTarget(id, hud->spec.value("pane").toString()));
}

KParts::ReadOnlyPart *MainWindow::coverPart(const QString &id) const
{
    // what owns the keyboard: a shown session-wide program, else the main pane's own overlay
    for (const QString &pane : {QString(), QStringLiteral("left")}) {
        const Overlay ov = m_overlays.value(slotKey(id, pane));
        if (ov.part && !ov.hidden)
            return ov.part;
    }
    return m_panes.value(id).main;
}

bool MainWindow::openOverlay(const QString &id, const QString &pane, const QString &command, const QString &cwd, int sizePercent, double width,
                             double height, const QString &color, bool wait, std::function<void()> onClose, QString *error)
{
    const Panes p = m_panes.value(id);
    const Session *s = m_store.session(id);
    const QString key = slotKey(id, pane);
    if (!p.view || !s)
        return *error = QStringLiteral("session has no terminal"), false;
    if (m_overlays.contains(key))
        return *error = m_overlays.value(key).hidden ? QStringLiteral("overlay hidden") : pane.isEmpty() ? QStringLiteral("overlay already open") : QStringLiteral("pane overlay already open"), false;
    QWidget *under = pane.isEmpty() ? p.view : paneWidget(id, pane);
    if (!under || (pane == QLatin1String("right") && !s->splitVisible))
        return *error = QStringLiteral("pane not visible"), false;
    if (pane.isEmpty())
        closeHud(id); // a program replaces the HUD in the session-wide slot

    Overlay ov;
    ov.sizePercent = sizePercent;
    ov.width = width;
    ov.height = height;
    ov.command = command;
    ov.onClose = std::move(onClose);
    ov.codeFile = QDir::tempPath() + QStringLiteral("/agterm-ovl-") + QUuid::createUuid().toString(QUuid::WithoutBraces);
    auto *frame = new QFrame(p.view);
    frame->setObjectName(QStringLiteral("agtermOverlay"));
    auto *box = new QVBoxLayout(frame);
    box->setContentsMargins(sizePercent > 0 ? QMargins(1, 1, 1, 1) : QMargins());
    if (sizePercent > 0) { // floating: framed over the visible session
        frame->setFrameShape(QFrame::StyledPanel);
        frame->setAutoFillBackground(true);
        if (!color.isEmpty()) {
            QPalette pal = frame->palette();
            pal.setColor(QPalette::Window, QColor(color)); // the frame only: Konsole's colours come from the profile
            frame->setPalette(pal);
        }
    }
    // master's wrapper: the command and the code file travel in the environment, output is untouched
    QString wrapper = QStringLiteral("( eval \"$AGTERM_OVL_CMD\" ); c=$?; echo $c > \"$AGTERM_OVL_CODE\"");
    if (wait)
        wrapper += QStringLiteral("; printf '\\n[exited %s, press a key to close]' \"$c\"; stty -icanon -echo; head -c1 >/dev/null");
    wrapper.replace(QLatin1Char('\''), QStringLiteral("'\\''"));
    const QString dir = !cwd.isEmpty() ? cwd : liveCwd(id).isEmpty() ? s->cwd : liveCwd(id);
    ov.part = spawnPart(id, QStringLiteral("overlay"), dir, QStringLiteral("exec /bin/sh -c '%1'").arg(wrapper), frame,
                        {QStringLiteral("AGTERM_OVL_CMD=") + command, QStringLiteral("AGTERM_OVL_CODE=") + ov.codeFile});
    if (!ov.part) {
        delete frame;
        return *error = QStringLiteral("cannot start the overlay terminal"), false;
    }
    box->addWidget(ov.part->widget());
    ov.frame = frame;
    connect(ov.part, &QObject::destroyed, this, [this, key, part = ov.part] { overlayExited(key, part); });
    under->installEventFilter(this); // a divider drag or window resize re-lays the cover
    under->setProperty("agtermOverlayHost", id);
    p.view->installEventFilter(this);
    p.view->setProperty("agtermOverlayHost", id);
    m_overlays.insert(key, ov);
    frame->show();
    layoutOverlays(id);
    if (isVisible() && !p.view->isVisible()) { // a background overlay still needs a screen size for its program
        QWidget *current = m_stack->currentWidget();
        m_stack->setCurrentWidget(p.view);
        m_stack->setCurrentWidget(current);
    }
    if (id == m_store.selected && isActiveWindow())
        ov.part->widget()->setFocus();
    syncChrome();
    return true;
}

void MainWindow::overlayExited(const QString &key, KParts::ReadOnlyPart *part)
{
    if (m_quitting || m_overlays.value(key).part != part)
        return; // closed by hand, or torn down with its session
    Overlay ov = m_overlays.take(key);
    if (QFile f(ov.codeFile); f.open(QIODevice::ReadOnly)) {
        bool ok = false;
        const int code = f.readAll().trimmed().toInt(&ok);
        if (ok)
            m_overlayResults.insert(key, code);
        f.remove();
    }
    if (ov.frame)
        ov.frame->deleteLater();
    const QString id = key.section(QLatin1Char('|'), 0, 0);
    if (id == m_store.selected && isActiveWindow())
        if (KParts::ReadOnlyPart *front = coverPart(id); front && front != part)
            front->widget()->setFocus();
    syncChrome();
    if (ov.onClose)
        ov.onClose();
}

void MainWindow::closeOverlay(const QString &key)
{
    Overlay ov = m_overlays.take(key);
    QFile::remove(ov.codeFile);
    delete ov.part; // hangs up the program
    delete ov.frame;
    const QString id = key.section(QLatin1Char('|'), 0, 0);
    if (id == m_store.selected && isActiveWindow())
        if (KParts::ReadOnlyPart *front = coverPart(id))
            front->widget()->setFocus();
    syncChrome();
    if (ov.onClose)
        ov.onClose();
}

bool MainWindow::closeHud(const QString &id)
{
    QPointer<QWidget> hud = m_huds.take(id);
    const bool had = hud;
    delete hud.data();
    return had;
}

bool MainWindow::openHud(const QString &id, const QJsonObject &spec, QString *error)
{
    const Panes p = m_panes.value(id);
    const Session *s = m_store.session(id);
    if (!p.view || !s)
        return *error = QStringLiteral("session has no terminal"), false;
    const Overlay ov = m_overlays.value(slotKey(id, {}));
    if (ov.part)
        return *error = QStringLiteral("overlay already open"), false;
    if (spec.value("pane").toString() == QLatin1String("right") && !s->splitVisible)
        return *error = QStringLiteral("pane not visible"), false;
    closeHud(id); // a second open replaces the first
    auto *hud = new Hud(p.view);
    connect(&hud->hideTimer, &QTimer::timeout, this, [this, id] { closeHud(id); });
    hud->apply(spec);
    m_huds.insert(id, hud);
    p.view->installEventFilter(this);
    p.view->setProperty("agtermOverlayHost", id);
    hud->show();
    layoutOverlays(id);
    return true;
}

bool MainWindow::overlayCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error)
{
    const QString pane = args.value("pane").toString();
    const QString key = slotKey(id, pane);
    auto *hud = static_cast<Hud *>(m_huds.value(id).data());
    if (cmd == QLatin1String("session.overlay.open")) {
        QString cwd = args.value("cwd").toString();
        if (cwd.startsWith(QLatin1Char('~')))
            cwd = QDir::homePath() + cwd.mid(1);
        if (!cwd.isEmpty() && !QFileInfo(cwd).isDir())
            return *error = QStringLiteral("not a directory: %1").arg(cwd), false;
        return openOverlay(id, pane, args.value("command").toString(), cwd, args.value("sizePercent").toInt(), args.value("width").toDouble(),
                           args.value("height").toDouble(), args.value("color").toString(), args.value("wait").toBool(), {}, error);
    }
    if (cmd == QLatin1String("session.overlay.close")) {
        if (m_overlays.contains(key))
            closeOverlay(key);
        else if (!(pane.isEmpty() && closeHud(id)))
            return *error = QStringLiteral("no overlay"), false;
        return true;
    }
    if (cmd == QLatin1String("session.overlay.result")) {
        if (m_overlays.contains(key))
            return *error = QStringLiteral("overlay still running"), false;
        if (!m_overlayResults.contains(key))
            return *error = pane.isEmpty() && hud ? QStringLiteral("no overlay result: the slot holds a hud") : QStringLiteral("no overlay result"), false;
        result->insert("exitCode", m_overlayResults.value(key));
        return true;
    }
    if (cmd == QLatin1String("session.overlay.text")) {
        const Overlay ov = m_overlays.value(key);
        if (!ov.part)
            return *error = pane.isEmpty() && hud ? QStringLiteral("no overlay to read: the slot holds a hud") : QStringLiteral("no overlay"), false;
        QString text;
        QObject *ks = sessionOf(ov.part);
        if (!ks || !QMetaObject::invokeMethod(ks, "getAllDisplayedText", Q_RETURN_ARG(QString, text), Q_ARG(bool, true)))
            return *error = QStringLiteral("overlay not realized"), false;
        if (const int lines = args.value("lines").toInt(); lines > 0) {
            QStringList all = text.split(QLatin1Char('\n'));
            while (!all.isEmpty() && all.last().isEmpty())
                all.removeLast();
            text = all.mid(qMax(0, int(all.size()) - lines)).join(QLatin1Char('\n'));
        }
        result->insert("text", text);
        return true;
    }
    if (cmd == QLatin1String("session.overlay.hide") || cmd == QLatin1String("session.overlay.show") || cmd == QLatin1String("session.overlay.toggle")) {
        QStringList keys;
        for (const QString &p : pane.isEmpty() ? QStringList{QString(), QStringLiteral("left"), QStringLiteral("right")} : QStringList{pane})
            if (m_overlays.contains(slotKey(id, p)))
                keys << slotKey(id, p);
        if (keys.isEmpty())
            return *error = QStringLiteral("no overlay"), false;
        bool anyShown = false;
        for (const QString &k : keys)
            anyShown |= !m_overlays.value(k).hidden;
        const bool hide = cmd == QLatin1String("session.overlay.hide") || (cmd == QLatin1String("session.overlay.toggle") && anyShown);
        for (const QString &k : keys) {
            Overlay &ov = m_overlays[k];
            ov.hidden = hide;
            ov.frame->setVisible(!hide); // the program keeps running underneath
        }
        if (id == m_store.selected)
            if (KParts::ReadOnlyPart *front = coverPart(id))
                front->widget()->setFocus();
        result->insert("text", hide ? QStringLiteral("hidden") : QStringLiteral("shown"));
        syncChrome();
        return true;
    }
    if (cmd == QLatin1String("session.overlay.resize")) {
        Overlay *ov = m_overlays.contains(slotKey(id, {})) ? &m_overlays[slotKey(id, {})] : nullptr;
        if (!ov && hud) {
            if (args.value("full").toBool())
                return *error = QStringLiteral("a hud is always floating: pass --size-percent, not --full"), false;
            QJsonObject spec = hud->spec;
            if (args.contains("sizePercent"))
                spec.insert("sizePercent", args.value("sizePercent"));
            hud->spec = spec; // a resize keeps the hide-after clock running
        } else if (!ov) {
            return *error = QStringLiteral("no overlay"), false;
        } else if (args.value("full").toBool()) {
            ov->sizePercent = 0;
            ov->width = ov->height = 0;
        } else {
            // points alone on a full overlay float it at the full percent on the other axis
            ov->sizePercent = args.contains("sizePercent") ? args.value("sizePercent").toInt() : ov->sizePercent > 0 ? ov->sizePercent : 100;
            if (args.contains("width"))
                ov->width = args.value("width").toDouble();
            if (args.contains("height"))
                ov->height = args.value("height").toDouble();
        }
        layoutOverlays(id);
        return true;
    }
    if (cmd == QLatin1String("session.hud.open"))
        return openHud(id, args, error);
    if (cmd == QLatin1String("session.hud.update")) {
        if (!hud)
            return *error = QStringLiteral("no hud"), false;
        QJsonObject spec = args; // replaces the whole spec; font size and background are fixed at open
        for (const char *fixed : {"fontSize", "color"})
            if (hud->spec.contains(QLatin1String(fixed)))
                spec.insert(QLatin1String(fixed), hud->spec.value(QLatin1String(fixed)));
        hud->apply(spec);
        layoutOverlays(id);
        return true;
    }
    if (cmd == QLatin1String("session.hud.close")) {
        if (!closeHud(id))
            return *error = QStringLiteral("no hud"), false;
        return true;
    }
    return *error = QStringLiteral("unknown command '%1'").arg(cmd), false;
}

QJsonObject MainWindow::sessionExtras(const QString &id) const
{
    QJsonObject out;
    const Overlay full = m_overlays.value(slotKey(id, {}));
    out.insert("overlay", bool(full.part));
    if (full.part && full.sizePercent > 0) {
        out.insert("overlaySizePercent", full.sizePercent);
        if (full.frame) {
            out.insert("overlayWidth", full.frame->width());
            out.insert("overlayHeight", full.frame->height());
        }
    }
    QJsonArray panes, hidden;
    if (full.hidden)
        hidden << QStringLiteral("session");
    for (const QString &pane : {QStringLiteral("left"), QStringLiteral("right")})
        if (const Overlay ov = m_overlays.value(slotKey(id, pane)); ov.part) {
            panes << pane;
            if (ov.hidden)
                hidden << pane;
        }
    if (!panes.isEmpty())
        out.insert("paneOverlays", panes);
    if (!hidden.isEmpty())
        out.insert("hiddenOverlays", hidden);
    if (auto *hud = static_cast<Hud *>(m_huds.value(id).data())) {
        QJsonObject h = hud->spec;
        h.insert("spinner", h.value("spinner").toString(QStringLiteral("none")));
        h.insert("hideAfter", h.value("hideAfter").toDouble());
        h.insert("markdown", h.value("markdown").toBool());
        h.insert("sticky", h.value("sticky").toBool());
        h.insert("frame", h.value("frame").toBool(true));
        h.insert("backgroundColor", h.take("color"));
        if (h.value("backgroundColor").isNull())
            h.remove("backgroundColor");
        out.insert("hud", h);
    }
    return out;
}

void MainWindow::toggleOverlays()
{
    QJsonObject result;
    QString error;
    if (m_store.session(m_store.selected) && !overlayCommand(QStringLiteral("session.overlay.toggle"), m_store.selected, {}, &result, &error))
        statusBar()->showMessage(error, 2000);
}

bool MainWindow::hasHideableOverlay(const QString &id, bool *anyShown) const
{
    bool any = false;
    *anyShown = false;
    for (const QString &pane : {QString(), QStringLiteral("left"), QStringLiteral("right")})
        if (const Overlay ov = m_overlays.value(slotKey(id, pane)); ov.part) {
            any = true;
            *anyShown |= !ov.hidden;
        }
    return any;
}

void MainWindow::forgetOverlays(const QString &id)
{
    for (const QString &pane : {QString(), QStringLiteral("left"), QStringLiteral("right")}) {
        const Overlay ov = m_overlays.take(slotKey(id, pane));
        if (!ov.codeFile.isEmpty())
            QFile::remove(ov.codeFile);
        m_overlayResults.remove(slotKey(id, pane));
    }
    m_huds.remove(id);
}
