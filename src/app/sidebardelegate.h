#pragma once

#include <QStyledItemDelegate>
#include <QTreeWidget>

namespace SidebarRole {
enum { Id = Qt::UserRole, Kind, Status, Sub, Count, Attention, Expanded };
enum { Workspace = 1, Session };
}

// Paints workspace headers and two-line session rows with a status glyph, per the design canvas.
class SidebarDelegate : public QStyledItemDelegate
{
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    int spinnerPhase = 0; // degrees; advanced by the window while any session is active

    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override;
    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const override;
};

// The style's row panel and branch arrows would paint under ours; the delegate owns the whole row.
class SidebarView : public QTreeWidget
{
public:
    using QTreeWidget::QTreeWidget;

protected:
    void drawRow(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override
    {
        // the base drawRow is what normally adds per-row selection and hover state
        QStyleOptionViewItem o = option;
        o.state.setFlag(QStyle::State_Selected, selectionModel()->isSelected(index));
        o.state.setFlag(QStyle::State_MouseOver, viewport()->underMouse() && indexAt(viewport()->mapFromGlobal(QCursor::pos())) == index);
        itemDelegateForIndex(index)->paint(painter, o, index);
    }
    void drawBranches(QPainter *, const QRect &, const QModelIndex &) const override { }
};
