// View ▸ Edit Flagged Sessions… / Edit Focused Workspaces…, and auto-follow of blocked sessions.
#include "mainwindow.h"

#include "sidebar.h"
#include "store.h"

#include <QDialog>
#include <QDialogButtonBox>
#include <QListWidget>
#include <QVBoxLayout>

// a live checklist: Return, a click or the box toggles one row and applies it at once, as master's editors
static void checklist(QWidget *parent, const QString &title, const QList<std::tuple<QString, QString, bool>> &rows,
                      const std::function<void(const QString &, bool)> &apply)
{
    auto *dlg = new QDialog(parent);
    dlg->setAttribute(Qt::WA_DeleteOnClose);
    dlg->setWindowTitle(title);
    dlg->setObjectName(QStringLiteral("checklist"));
    auto *list = new QListWidget;
    for (const auto &[id, text, on] : rows) {
        auto *item = new QListWidgetItem(text, list);
        item->setData(Qt::UserRole, id);
        item->setFlags(Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsUserCheckable);
        item->setCheckState(on ? Qt::Checked : Qt::Unchecked);
    }
    list->setCurrentRow(0);
    QObject::connect(list, &QListWidget::itemChanged, dlg, [apply](QListWidgetItem *item) {
        apply(item->data(Qt::UserRole).toString(), item->checkState() == Qt::Checked);
    });
    QObject::connect(list, &QListWidget::itemActivated, dlg, [](QListWidgetItem *item) {
        item->setCheckState(item->checkState() == Qt::Checked ? Qt::Unchecked : Qt::Checked);
    });
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close);
    QObject::connect(buttons, &QDialogButtonBox::rejected, dlg, &QDialog::reject);
    auto *layout = new QVBoxLayout(dlg);
    layout->addWidget(list);
    layout->addWidget(buttons);
    dlg->resize(420, 460);
    dlg->open();
}

void MainWindow::editFlaggedSessions()
{
    QList<std::tuple<QString, QString, bool>> rows;
    for (const Workspace &w : std::as_const(m_store.workspaces))
        for (const Session &s : w.sessions)
            rows.append({s.id, s.displayName() + QStringLiteral(" : ") + w.name, s.flagged});
    checklist(this, tr("Edit Flagged Sessions"), rows, [this](const QString &id, bool on) { m_store.setFlag(id, on); });
}

void MainWindow::editFocusedWorkspaces()
{
    QList<std::tuple<QString, QString, bool>> rows;
    for (const Workspace &w : std::as_const(m_store.workspaces))
        rows.append({w.id, w.name, m_store.focused.contains(w.id)});
    // marking never narrows the tree on its own; the filter button applies the set
    checklist(this, tr("Edit Focused Workspaces"), rows,
              [this](const QString &id, bool on) { m_store.focusWorkspace(id, on ? QStringLiteral("add") : QStringLiteral("off")); });
}

qint64 MainWindow::autoFollowMs() const
{
    static const QHash<QString, qint64> timeouts{{"s5", 5000}, {"s10", 10000}, {"s30", 30000}, {"s60", 60000}, {"m5", 300000}};
    return timeouts.value(m_store.settings.autoFollowAttention, 0);
}

void MainWindow::trackBlocked(const QString &id, const QString &status)
{
    if (status != QLatin1String("blocked")) { // leaving blocked makes the next block eligible again
        m_blockedSince.remove(id);
        m_followShown.remove(id);
    } else if (!m_blockedSince.contains(id)) {
        m_blockedSince.insert(id, QDateTime::currentMSecsSinceEpoch());
    }
    if (id == m_store.selected && status == QLatin1String("blocked"))
        m_followShown.insert(id); // parked on it: shown
}

QString MainWindow::autoFollowTick(qint64 idleMs)
{
    const qint64 timeout = autoFollowMs();
    const Session *cur = m_store.session(m_store.selected);
    if (cur && cur->status == QLatin1String("blocked"))
        m_followShown.insert(cur->id);
    if (!timeout || idleMs < timeout || (cur && m_store.settings.autoFollowStayOnActive && cur->status == QLatin1String("active")))
        return {};
    QString oldest;
    for (auto it = m_blockedSince.begin(); it != m_blockedSince.end(); ++it) {
        const Session *s = m_store.session(it.key());
        if (s && s->status == QLatin1String("blocked") && !m_followShown.contains(it.key())
            && (oldest.isEmpty() || it.value() < m_blockedSince.value(oldest)))
            oldest = it.key();
    }
    if (oldest.isEmpty())
        return {};
    m_followShown.insert(oldest); // each block pulls you once
    m_store.select(oldest);
    return oldest;
}
