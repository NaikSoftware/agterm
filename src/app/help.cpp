// Help ▸ Install … and master's first-launch welcome that points them out.
#include "help.h"

#include "installers.h"

#include <QCheckBox>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFileInfo>
#include <QLabel>
#include <QMenu>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>
#include <QVBoxLayout>

// the shipped package: installed under share/agterm-qt, or the source tree for a build-tree run
QString bundled(const QString &name)
{
    // next to the binary first, so a build-tree run never picks up an older installed copy from the data dirs
    QStringList candidates{QCoreApplication::applicationDirPath() + QStringLiteral("/../share/agterm-qt/") + name};
#ifdef AGTERM_SOURCE_SHARE
    candidates << QStringLiteral(AGTERM_SOURCE_SHARE "/") + name;
#endif
    candidates << QStandardPaths::locate(QStandardPaths::GenericDataLocation, QStringLiteral("agterm-qt/") + name, QStandardPaths::LocateDirectory);
    for (const QString &c : candidates)
        if (!c.isEmpty() && QFileInfo(c).isDir())
            return QFileInfo(c).canonicalFilePath();
    return {};
}

static QString agtermctl()
{
    return QCoreApplication::applicationDirPath() + QStringLiteral("/agtermctl");
}

// master's probe: the login shell says which OpenCode it runs and where v2 keeps its config; asks when it cannot tell
Install::OpenCode probeOpenCode(const QString &home, QWidget *parent)
{
    QProcess p;
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("AGTERM_SESSION_ID"));
    env.insert(QStringLiteral("HOME"), home);
    p.setProcessEnvironment(env);
    p.start(qEnvironmentVariable("SHELL", QStringLiteral("/bin/sh")),
            {QStringLiteral("-ilc"), QStringLiteral("printf '%s\\n%s\\n' \"${OPENCODE_CONFIG_DIR-}\" \"${XDG_CONFIG_HOME:-$HOME/.config}\"; "
                                                    "exec /usr/bin/env opencode --version")});
    const bool ran = p.waitForFinished(3000);
    if (!ran)
        p.kill();
    const QStringList out = QString::fromUtf8(p.readAllStandardOutput()).split(QLatin1Char('\n'));
    Install::OpenCode oc;
    const QString override = out.value(0).trimmed(), xdg = out.value(1).trimmed();
    oc.v2Dir = !override.isEmpty() ? QDir(home).absoluteFilePath(override) : xdg.isEmpty() ? QString() : xdg + QStringLiteral("/opencode");
    static const QRegularExpression version(QStringLiteral("^(?:opencode )?v?(\\d+)\\.\\d+\\.\\d+"));
    const auto m = version.match(out.mid(2).join(QLatin1Char('\n')).trimmed());
    const int major = m.hasMatch() ? m.captured(1).toInt() : 0;
    const bool legacy = QFileInfo(home + QStringLiteral("/.config/opencode")).isDir();
    if (major == 1 || major == 2)
        return oc.version = major, oc;
    if (!legacy && !QFileInfo(oc.v2Dir).isDir())
        return oc.version = -1, oc;
    if (!parent)
        return oc.version = 0, oc; // --install: nobody to ask
    QMessageBox box(QMessageBox::Question, QObject::tr("Choose OpenCode Version"),
                    QObject::tr("Could not determine the OpenCode version in your login shell (opencode --version). Choose the version you use, or skip "
                                "OpenCode and install the other hooks."),
                    QMessageBox::NoButton, parent);
    QPushButton *skip = box.addButton(QObject::tr("Skip OpenCode"), QMessageBox::RejectRole);
    QPushButton *v1 = box.addButton(QObject::tr("OpenCode v1"), QMessageBox::AcceptRole);
    box.addButton(QObject::tr("OpenCode v2"), QMessageBox::AcceptRole);
    box.exec();
    oc.version = box.clickedButton() == skip ? 0 : box.clickedButton() == v1 ? 1 : 2;
    return oc;
}

Install::Report runInstaller(const QString &which, const QString &home, QWidget *parent)
{
    if (which == QLatin1String("agent-hooks"))
        return Install::agentHooks(home, bundled(QStringLiteral("agent-status")), agtermctl(), probeOpenCode(home, parent));
    if (which == QLatin1String("cli"))
        return Install::commandLineTool(home, agtermctl());
    if (which == QLatin1String("skill"))
        return Install::skill(home, bundled(QStringLiteral("skill/agterm")));
    Install::Report r;
    r.error = QStringLiteral("unknown installer '%1' (agent-hooks, cli, skill)").arg(which);
    return r;
}

void showReport(QWidget *parent, const Install::Report &r)
{
    if (!r.error.isEmpty())
        return void(QMessageBox::critical(parent, QObject::tr("Install Failed"), r.error));
    QMessageBox box(r.warning ? QMessageBox::Warning : QMessageBox::Information, r.title, r.text(), QMessageBox::Ok, parent);
    box.exec();
}

void addHelpMenu(QMenu *help, QWidget *window)
{
    help->addAction(QObject::tr("Developer Documentation…"), window, [] { QDesktopServices::openUrl(QUrl(QStringLiteral("https://agterm.com/docs#agtermctl"))); });
    help->addSeparator();
    for (const auto &[which, title] : {std::pair{"cli", "Install Command Line Tool…"}, {"agent-hooks", "Install Agent Status Hooks…"}, {"skill", "Install Agent Skill…"}})
        help->addAction(QObject::tr(title), window, [window, which] { showReport(window, runInstaller(QLatin1String(which), QDir::homePath(), window)); });
}

void showWelcome(QWidget *window)
{
    auto *dlg = new QDialog(window);
    dlg->setAttribute(Qt::WA_DeleteOnClose);
    dlg->setObjectName(QStringLiteral("welcome"));
    dlg->setWindowTitle(QObject::tr("Welcome to agterm"));
    auto *layout = new QVBoxLayout(dlg);
    auto *title = new QLabel(QObject::tr("Welcome to agterm"));
    QFont f = title->font();
    f.setWeight(QFont::DemiBold);
    f.setPointSizeF(f.pointSizeF() * 1.2);
    title->setFont(f);
    layout->addWidget(title);
    auto *text = new QLabel(QObject::tr("agterm ships optional extras. These two install from here, and all of them from the Help menu at any time:\n\n"
                                        "The agent skill teaches Claude Code and Codex to drive agterm over its control socket.\n\n"
                                        "The agent status hooks make an agent session report active, blocked or completed in the sidebar.\n\n"
                                        "The command line tool puts agtermctl on your PATH. An install with cmake --install already has it, so that "
                                        "one is only for running from a build."));
    text->setWordWrap(true);
    layout->addWidget(text);
    auto *skill = new QCheckBox(QObject::tr("Install the agent skill"));
    auto *hooks = new QCheckBox(QObject::tr("Install the agent status hooks"));
    skill->setChecked(true);
    hooks->setChecked(true);
    layout->addWidget(skill);
    layout->addWidget(hooks);
    auto *buttons = new QDialogButtonBox;
    QPushButton *install = buttons->addButton(QObject::tr("Install"), QDialogButtonBox::AcceptRole);
    buttons->addButton(QObject::tr("Later"), QDialogButtonBox::RejectRole);
    install->setDefault(true);
    QObject::connect(buttons, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
    QObject::connect(buttons, &QDialogButtonBox::accepted, dlg, [=] {
        const bool wantSkill = skill->isChecked(), wantHooks = hooks->isChecked();
        dlg->accept();
        if (wantSkill)
            showReport(window, runInstaller(QStringLiteral("skill"), QDir::homePath(), window));
        if (wantHooks)
            showReport(window, runInstaller(QStringLiteral("agent-hooks"), QDir::homePath(), window));
    });
    layout->addWidget(buttons);
    dlg->resize(520, dlg->sizeHint().height());
    dlg->open();
}
