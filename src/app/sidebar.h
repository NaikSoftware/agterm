#pragma once

#include <QSet>
#include <QStyledItemDelegate>
#include <QTimer>
#include <QTreeWidget>

class Store;

// A launcher's icon as a template tinted `color`: the terminal glyph, or the agent's logo.
QIcon launcherIcon(const QString &launcherId, const QColor &color);

namespace SidebarRole {
enum { Id = Qt::UserRole, Kind, Status, Blink, Agent, Flagged, Expanded };
enum { WorkspaceRow = 1, SessionRow };
}

class SidebarDelegate : public QStyledItemDelegate
{
public:
    SidebarDelegate(class Sidebar *sidebar);
    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    void updateEditorGeometry(QWidget *editor, const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    void setEditorData(QWidget *editor, const QModelIndex &index) const override;

private:
    Sidebar *m_sidebar;
};

// The workspace -> session tree, drawn like agterm's sidebar.
class Sidebar : public QTreeWidget
{
    Q_OBJECT
public:
    explicit Sidebar(Store &store, QWidget *parent = nullptr);
    void rebuild();
    void setFlaggedView(bool on);
    bool flaggedView() const { return m_flaggedView; }
    QStringList selectedSessionIds() const;
    bool editing() const { return state() == EditingState; }
    QString lastLauncher() const;

    // geometry shared by painting and hit-testing
    static QRect addButtonRect(const QRect &row);
    static QRect repeatButtonRect(const QRect &row);
    QModelIndex hovered() const { return m_hovered; }
    int blinkAlpha() const { return m_blinkAlpha; }

Q_SIGNALS:
    void launcherMenuRequested(const QString &workspaceId, const QPoint &globalPos);
    void repeatRequested(const QString &workspaceId);
    void foldersDropped(const QString &workspaceId, const QStringList &paths);
    void renameRequested(const QString &kind, const QString &id, const QString &name);

protected:
    void drawRow(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    void drawBranches(QPainter *, const QRect &, const QModelIndex &) const override { }
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void leaveEvent(QEvent *event) override;
    void mouseDoubleClickEvent(QMouseEvent *event) override;
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dragMoveEvent(QDragMoveEvent *event) override;
    void dropEvent(QDropEvent *event) override;
    void dragLeaveEvent(QDragLeaveEvent *event) override;
    void startDrag(Qt::DropActions supportedActions) override;
    void paintEvent(QPaintEvent *event) override;

private:
    struct Drop {
        QString workspaceId;
        int index = -1; // -1 = end
        int workspaceIndex = -1;
        QRect line;
    };
    Drop dropTarget(const QPoint &pos, bool workspaceDrag) const;
    QRect m_dropLine;
    Store &m_store;
    bool m_flaggedView = false;
    bool m_rebuilding = false;
    QSet<QString> m_collapsed;
    QModelIndex m_hovered;
    QTimer m_blinkTimer;
    int m_blinkAlpha = 255;
    int m_blinkPhase = 0;
    friend class MainWindow; // persists the collapsed set
};
