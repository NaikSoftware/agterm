// Settings: master's six tabs as KDE pages; every control applies live, as in agterm.
#include "mainwindow.h"

#include "hooks.h"
#include "sidebar.h"
#include "store.h"

#include <KPageDialog>

#include <QCheckBox>
#include <QColorDialog>
#include <QComboBox>
#include <QStandardItemModel>
#include <QDialogButtonBox>
#include <QDir>
#include <QDirIterator>
#include <QFileDialog>
#include <QFontDatabase>
#include <QFormLayout>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPainter>
#include <QPushButton>
#include <QSpinBox>
#include <QStandardPaths>
#include <QToolButton>
#include <QVBoxLayout>

namespace {
QComboBox *choice(const QList<std::pair<QString, QString>> &options, const QString &current)
{
    auto *box = new QComboBox;
    for (const auto &[text, value] : options)
        box->addItem(text, value);
    box->setCurrentIndex(qMax(0, box->findData(current)));
    return box;
}

QGroupBox *group(const QString &title, QLayout *layout)
{
    auto *g = new QGroupBox(title);
    g->setLayout(layout);
    return g;
}

QStringList soundNames()
{
    QStringList names;
    for (const QString &d : QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("sounds/freedesktop/stereo"), QStandardPaths::LocateDirectory))
        for (QDirIterator it(d, {QStringLiteral("*.oga")}, QDir::Files); it.hasNext();)
            names << it.nextFileInfo().completeBaseName();
    names.removeDuplicates();
    names.sort();
    return names;
}

QIcon glyphIcon(const QColor &color, const QString &shape)
{
    QPixmap pm(32, 32);
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing);
    p.setPen(Qt::NoPen);
    p.setBrush(color);
    drawStatusGlyph(&p, QPointF(16, 16), 10, shape);
    p.end();
    pm.setDevicePixelRatio(2);
    return QIcon(pm);
}
} // namespace

void MainWindow::showSettings()
{
    if (auto *open = findChild<KPageDialog *>(QStringLiteral("settingsDialog"))) {
        open->raise();
        open->activateWindow();
        return;
    }
    auto *dlg = new KPageDialog(this);
    dlg->setObjectName(QStringLiteral("settingsDialog"));
    dlg->setAttribute(Qt::WA_DeleteOnClose);
    dlg->setWindowTitle(tr("Configure agterm"));
    dlg->setFaceType(KPageDialog::List);
    dlg->setStandardButtons(QDialogButtonBox::Close);
    dlg->resize(760, 560);
    const Settings &cur = m_store.settings;
    auto update = [this](const std::function<void(Settings &)> &change) {
        Settings s = m_store.settings;
        change(s);
        m_store.setSettings(s);
    };
    auto check = [&](const QString &text, bool on, std::function<void(Settings &, bool)> apply) {
        auto *b = new QCheckBox(text);
        b->setChecked(on);
        connect(b, &QCheckBox::toggled, dlg, [update, apply](bool v) { update([&](Settings &s) { apply(s, v); }); });
        return b;
    };
    auto picker = [&](const QList<std::pair<QString, QString>> &options, const QString &current, std::function<void(Settings &, const QString &)> apply) {
        QComboBox *box = choice(options, current);
        connect(box, &QComboBox::currentIndexChanged, dlg, [update, apply, box] { update([&](Settings &s) { apply(s, box->currentData().toString()); }); });
        return box;
    };
    auto sizeSpin = [&](double value, std::function<void(Settings &, double)> apply) {
        auto *spin = new QSpinBox;
        spin->setRange(0, 48);
        spin->setSpecialValueText(tr("Default"));
        spin->setValue(int(value));
        connect(spin, &QSpinBox::valueChanged, dlg, [update, apply](int v) { update([&](Settings &s) { apply(s, v); }); });
        return spin;
    };
    auto page = [&](const QString &name, const QString &icon, const QList<QWidget *> &groups) {
        auto *w = new QWidget;
        auto *col = new QVBoxLayout(w);
        for (QWidget *g : groups)
            col->addWidget(g);
        col->addStretch(1);
        dlg->addPage(w, name)->setIcon(QIcon::fromTheme(icon));
    };

    // General
    auto *sessions = new QFormLayout;
    QComboBox *dirMode = picker({{tr("Home directory"), QStringLiteral("home")}, {tr("Workspace folder"), QStringLiteral("workspace")},
                                 {tr("Custom directory"), QStringLiteral("custom")}},
                                cur.newSessionDirectory, [](Settings &s, const QString &v) { s.newSessionDirectory = v; });
    auto *custom = new QLineEdit(cur.newSessionCustomDirectory);
    custom->setReadOnly(true);
    auto *choose = new QPushButton(tr("Choose…"));
    connect(choose, &QPushButton::clicked, dlg, [this, dlg, custom, update] {
        const QString d = QFileDialog::getExistingDirectory(dlg, tr("Folder for new sessions"), custom->text().isEmpty() ? QDir::homePath() : custom->text());
        if (d.isEmpty())
            return;
        custom->setText(d);
        update([&](Settings &s) { s.newSessionCustomDirectory = d; });
    });
    auto syncCustom = [dirMode, custom, choose] { custom->setEnabled(dirMode->currentData() == QLatin1String("custom")), choose->setEnabled(custom->isEnabled()); };
    connect(dirMode, &QComboBox::currentIndexChanged, dlg, syncCustom);
    syncCustom();
    auto *customRow = new QHBoxLayout;
    customRow->addWidget(custom, 1);
    customRow->addWidget(choose);
    sessions->addRow(tr("New sessions open in"), dirMode);
    sessions->addRow(QString(), customRow);
    sessions->addRow(tr("New sessions are added"),
                     picker({{tr("At the end of the workspace"), QStringLiteral("end")}, {tr("After the current session"), QStringLiteral("afterCurrent")}},
                            cur.newSessionPlacement, [](Settings &s, const QString &v) { s.newSessionPlacement = v; }));
    sessions->addRow(check(tr("Confirm before closing a session"), cur.confirmCloseSession, [](Settings &s, bool v) { s.confirmCloseSession = v; }));
    sessions->addRow(check(tr("Allow undo after closing sessions and workspaces"), cur.closeUndo, [](Settings &s, bool v) { s.closeUndo = v; }));
    QComboBox *restoreBox = picker({{tr("Fresh shells"), QStringLiteral("none")}, {tr("Re-run commands"), QStringLiteral("rerun")}, {tr("Live sessions"), QStringLiteral("live")}},
                                   cur.restoreMode, [](Settings &s, const QString &v) { s.restoreMode = v; });
    if (auto *model = qobject_cast<QStandardItemModel *>(restoreBox->model()); model && cur.restoreMode != QLatin1String("live")) {
        model->item(2)->setEnabled(false); // no session daemon here: see restore.mode's unavailableReason
        model->item(2)->setToolTip(tr("Needs a detached session daemon (zmx), which agterm-qt does not have"));
    }
    sessions->addRow(tr("Restore sessions"), restoreBox);
    auto *restoreHint = new QLabel(tr("Changes apply after restarting agterm."));
    restoreHint->setForegroundRole(QPalette::PlaceholderText);
    sessions->addRow(QString(), restoreHint);
    auto *sidebar = new QFormLayout;
    sidebar->addRow(check(tr("Click a workspace row to expand or collapse"), cur.workspaceRowClickExpands,
                          [](Settings &s, bool v) { s.workspaceRowClickExpands = v; }));
    page(tr("General"), QStringLiteral("configure"), {group(tr("Sessions"), sessions), group(tr("Sidebar"), sidebar)});

    // Appearance: mapped onto each Konsole session at runtime; Default = what the Konsole profile sets
    auto *terminal = new QFormLayout;
    QList<std::pair<QString, QString>> families{{tr("Default"), QString()}};
    for (const QString &f : QFontDatabase::families())
        if (QFontDatabase::isFixedPitch(f))
            families.append({f, f});
    terminal->addRow(tr("Font name"), picker(families, cur.fontFamily, [](Settings &s, const QString &v) { s.fontFamily = v; }));
    terminal->addRow(tr("Font size"), sizeSpin(cur.fontSize, [](Settings &s, double v) { s.fontSize = v; }));
    terminal->addRow(tr("Cursor shape"), picker({{tr("Default"), QString()}, {tr("Block"), QStringLiteral("block")}, {tr("Bar"), QStringLiteral("bar")},
                                                 {tr("Underline"), QStringLiteral("underline")}},
                                                cur.cursorStyle, [](Settings &s, const QString &v) { s.cursorStyle = v; }));
    terminal->addRow(tr("Cursor blink"), picker({{tr("Default"), QString()}, {tr("Blink"), QStringLiteral("blink")}, {tr("Steady"), QStringLiteral("steady")}},
                                                cur.cursorBlink, [](Settings &s, const QString &v) { s.cursorBlink = v; }));
    QList<std::pair<QString, QString>> themeOptions{{tr("Profile default"), QString()}};
    for (const QString &t : themes())
        themeOptions.append({t, t});
    auto *themeRow = new QHBoxLayout;
    QComboBox *themeBox = picker(themeOptions, cur.theme, [](Settings &s, const QString &v) { s.theme = v; });
    themeRow->addWidget(themeBox, 1);
    auto *browse = new QPushButton(tr("Select Theme…"));
    connect(browse, &QPushButton::clicked, dlg, [this, dlg] {
        dlg->close(); // the picker previews on the terminals behind it
        selectTheme();
    });
    themeRow->addWidget(browse);
    terminal->addRow(tr("Theme"), themeRow);
    auto *window = new QFormLayout;
    window->addRow(tr("Sidebar font size"), sizeSpin(cur.sidebarFontSize, [](Settings &s, double v) { s.sidebarFontSize = v; }));
    window->addRow(tr("Palette and switcher font size"), sizeSpin(cur.interfaceFontSize, [](Settings &s, double v) { s.interfaceFontSize = v; }));
    page(tr("Appearance"), QStringLiteral("preferences-desktop-color"), {group(tr("Terminal"), terminal), group(tr("Window"), window)});

    // Interface: chrome this port has, by master's InterfaceElement names
    auto element = [&](const QString &name, const QString &text) {
        return check(text, cur.shows(name), [name](Settings &s, bool on) {
            s.hiddenInterfaceElements.removeAll(name);
            s.shownInterfaceElements.removeAll(name);
            (on ? s.shownInterfaceElements : s.hiddenInterfaceElements) << name;
        });
    };
    auto twoColumns = [](const QList<QWidget *> &boxes) {
        auto *grid = new QGridLayout;
        for (int i = 0; i < boxes.size(); ++i)
            grid->addWidget(boxes[i], i / 2, i % 2);
        return grid;
    };
    page(tr("Interface"), QStringLiteral("preferences-desktop-theme-global"),
         {group(tr("Title Bar"), twoColumns({element(QStringLiteral("filePanel"), tr("File panel toggle")), element(QStringLiteral("sidebarToggle"), tr("Sidebar toggle")),
                                             element(QStringLiteral("workspaceName"), tr("Workspace name")), element(QStringLiteral("sessionName"), tr("Session name")),
                                             element(QStringLiteral("recentSessions"), tr("Recent sessions")), element(QStringLiteral("split"), tr("Split view")),
                                             element(QStringLiteral("customCommands"), tr("Custom commands"))})),
          group(tr("Sidebar"), twoColumns({element(QStringLiteral("newSession"), tr("New session")), element(QStringLiteral("newWorkspace"), tr("New workspace")),
                                           element(QStringLiteral("focusFilter"), tr("Workspace filter")), element(QStringLiteral("flaggedView"), tr("Flagged view")),
                                           element(QStringLiteral("workspaceAddSession"), tr("Workspace add-session")),
                                           element(QStringLiteral("workspaceIcons"), tr("Workspace icons")), element(QStringLiteral("sessionIcons"), tr("Session icons"))}))});

    // Notifications
    QList<std::pair<QString, QString>> sounds{{tr("None"), QString()}};
    for (const QString &n : soundNames())
        sounds.append({n, n});
    auto *notes = new QFormLayout;
    notes->addRow(check(tr("Show notification banners"), cur.notificationsEnabled, [](Settings &s, bool v) { s.notificationsEnabled = v; }));
    notes->addRow(check(tr("Show notification badges"), cur.notificationBadgeEnabled, [](Settings &s, bool v) { s.notificationBadgeEnabled = v; }));
    notes->addRow(tr("Highlight taskbar entry"), picker({{tr("None"), QStringLiteral("off")}, {tr("Once"), QStringLiteral("once")},
                                                         {tr("Until focused"), QStringLiteral("untilFocused")}},
                                                        cur.dockBounce, [](Settings &s, const QString &v) { s.dockBounce = v; }));
    notes->addRow(tr("Notification sound"), picker(sounds, cur.notificationSoundName, [this](Settings &s, const QString &v) {
                      s.notificationSoundName = v;
                      playSound(v);
                  }));
    page(tr("Notifications"), QStringLiteral("preferences-desktop-notification"), {group(tr("Notifications"), notes)});

    // Agent Status
    auto *glyphs = new QFormLayout;
    QList<std::function<void()>> resetters;
    for (const QString &status : {QStringLiteral("active"), QStringLiteral("blocked"), QStringLiteral("completed")}) {
        auto *row = new QHBoxLayout;
        auto *color = new QToolButton;
        color->setObjectName(QStringLiteral("statusColor_") + status);
        auto *shape = new QComboBox;
        shape->setObjectName(QStringLiteral("statusShape_") + status);
        auto refresh = [this, status, color, shape] {
            const QColor c = statusColor(m_store.settings, status);
            color->setIcon(glyphIcon(c, QStringLiteral("circle")));
            QSignalBlocker block(shape);
            shape->clear();
            for (const char *sh : {"circle", "square", "triangle", "diamond", "capsule", "star"})
                shape->addItem(glyphIcon(c, QLatin1String(sh)), QString::fromLatin1(sh).left(1).toUpper() + QString::fromLatin1(sh).mid(1), QLatin1String(sh));
            shape->setCurrentIndex(shape->findData(statusShape(m_store.settings, status)));
        };
        refresh();
        resetters << refresh;
        auto field = [status](Settings &s) -> std::pair<QString *, QString *> {
            if (status == QLatin1String("active"))
                return {&s.activeStatusColorHex, &s.activeStatusShape};
            if (status == QLatin1String("blocked"))
                return {&s.blockedStatusColorHex, &s.blockedStatusShape};
            return {&s.completedStatusColorHex, &s.completedStatusShape};
        };
        connect(color, &QToolButton::clicked, dlg, [this, dlg, status, field, update, refresh] {
            const QColor c = QColorDialog::getColor(statusColor(m_store.settings, status), dlg, tr("%1 status colour").arg(status));
            if (c.isValid())
                update([&](Settings &s) { *field(s).first = c.name(); });
            refresh();
        });
        connect(shape, &QComboBox::currentIndexChanged, dlg, [shape, field, update] {
            update([&](Settings &s) { *field(s).second = shape->currentData().toString(); });
        });
        row->addWidget(color);
        row->addWidget(shape, 1);
        glyphs->addRow(status.left(1).toUpper() + status.mid(1), row);
    }
    auto *soundForm = new QFormLayout;
    QComboBox *blockedSound = picker(sounds, cur.blockedStatusSoundName, [this](Settings &s, const QString &v) {
        s.blockedStatusSoundName = v;
        playSound(v);
    });
    soundForm->addRow(tr("Blocked sound"), blockedSound);
    auto *typing = new QFormLayout;
    QComboBox *reset = picker({{tr("On first key"), QStringLiteral("firstKey")}, {tr("On Enter"), QStringLiteral("enter")}, {tr("Disabled"), QStringLiteral("never")}},
                              cur.statusReset, [](Settings &s, const QString &v) { s.statusReset = v; });
    typing->addRow(tr("Status reset"), reset);
    auto *nav = new QFormLayout;
    nav->addRow(check(tr("Attention navigation includes active sessions"), cur.attentionIncludesActive,
                      [](Settings &s, bool v) { s.attentionIncludesActive = v; }));
    auto *resetButton = new QPushButton(tr("Reset to defaults"));
    connect(resetButton, &QPushButton::clicked, dlg, [=, this] {
        // colours, shapes, sound and status reset back to the shipped values, as master
        update([](Settings &s) {
            const Settings d;
            s.activeStatusColorHex = s.blockedStatusColorHex = s.completedStatusColorHex = QString();
            s.activeStatusShape = s.blockedStatusShape = s.completedStatusShape = QString();
            s.blockedStatusSoundName = d.blockedStatusSoundName;
            s.statusReset = d.statusReset;
        });
        QSignalBlocker b1(blockedSound), b2(reset);
        blockedSound->setCurrentIndex(0);
        reset->setCurrentIndex(reset->findData(m_store.settings.statusReset));
        for (const auto &r : resetters)
            r();
    });
    auto *resetRow = new QHBoxLayout;
    resetRow->addStretch(1);
    resetRow->addWidget(resetButton);
    auto *resetBox = new QWidget;
    resetBox->setLayout(resetRow);
    page(tr("Agent Status"), QStringLiteral("dialog-information"),
         {group(tr("Colors and Shapes"), glyphs), group(tr("Sound"), soundForm), group(tr("Typing"), typing), group(tr("Navigation"), nav), resetBox});

    // Key Mapping
    auto *dirForm = new QVBoxLayout;
    auto *dirLabel = new QLabel(configDir());
    dirLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    auto *dirButtons = new QHBoxLayout;
    auto *chooseDir = new QPushButton(tr("Choose…"));
    auto *defaultDir = new QPushButton(tr("Use Default"));
    dirButtons->addWidget(dirLabel, 1);
    dirButtons->addWidget(chooseDir);
    dirButtons->addWidget(defaultDir);
    dirForm->addLayout(dirButtons);
    auto *dirNote = new QLabel(tr("The directory holding keymap.conf and hooks.conf. Changing it reloads both."));
    dirNote->setWordWrap(true);
    dirNote->setForegroundRole(QPalette::PlaceholderText);
    dirForm->addWidget(dirNote);
    auto *keymapDiags = new QListWidget;
    keymapDiags->setObjectName(QStringLiteral("keymapDiagnostics"));
    auto *hookDiags = new QListWidget;
    hookDiags->setObjectName(QStringLiteral("hookDiagnostics"));
    auto fill = [this, keymapDiags, hookDiags, dirLabel, defaultDir] {
        dirLabel->setText(configDir());
        defaultDir->setEnabled(!m_store.settings.configDirectory.isEmpty());
        for (auto [list, diags] : {std::pair{keymapDiags, m_keymap.diagnostics}, std::pair{hookDiags, m_hooks->diagnostics}}) {
            list->clear();
            for (const auto &d : diags)
                list->addItem(QStringLiteral("line %1: %2").arg(d.line).arg(d.message));
            if (diags.isEmpty())
                list->addItem(tr("No issues."));
            list->setMaximumHeight(110);
        }
    };
    fill();
    connect(chooseDir, &QPushButton::clicked, dlg, [this, dlg, update, fill] {
        const QString d = QFileDialog::getExistingDirectory(dlg, tr("Config directory"), configDir());
        if (!d.isEmpty())
            update([&](Settings &s) { s.configDirectory = d; });
        fill();
    });
    connect(defaultDir, &QPushButton::clicked, dlg, [update, fill] {
        update([](Settings &s) { s.configDirectory.clear(); });
        fill();
    });
    auto diagGroup = [&](QListWidget *list, const QString &editAction, std::function<void()> reload) {
        auto *col = new QVBoxLayout;
        col->addWidget(list);
        auto *row = new QHBoxLayout;
        row->addStretch(1);
        auto *edit = new QPushButton(m_actions.value(editAction)->text());
        connect(edit, &QPushButton::clicked, dlg, [this, dlg, editAction] {
            dlg->close();
            m_actions.value(editAction)->trigger();
        });
        auto *reloadButton = new QPushButton(tr("Reload"));
        connect(reloadButton, &QPushButton::clicked, dlg, [reload, fill] {
            reload();
            fill();
        });
        row->addWidget(edit);
        row->addWidget(reloadButton);
        col->addLayout(row);
        return col;
    };
    page(tr("Key Mapping"), QStringLiteral("preferences-desktop-keyboard"),
         {group(tr("Config Directory"), dirForm),
          group(tr("Diagnostics"), diagGroup(keymapDiags, QStringLiteral("edit_keymap"), [this] { reloadKeymap(); })),
          group(tr("Hooks"), diagGroup(hookDiags, QStringLiteral("edit_hooks"), [this] { reloadHooks(); }))});
    dlg->show();
}
