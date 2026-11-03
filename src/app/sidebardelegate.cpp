#include "sidebardelegate.h"

#include "theme.h"

#include <QApplication>
#include <QPainter>
#include <QPainterPath>

using namespace SidebarRole;

static void drawGlyph(QPainter *p, const QRectF &r, const QString &status, const Theme &t, int phase)
{
    const QPointF c = r.center();
    if (status == QLatin1String("active")) {
        const QRectF ring(c.x() - 6, c.y() - 6, 12, 12);
        p->setPen(QPen(Theme::alpha(t.accent, 64), 2));
        p->drawEllipse(ring);
        p->setPen(QPen(t.accent, 2, Qt::SolidLine, Qt::RoundCap));
        p->drawArc(ring, (90 - phase) * 16, -90 * 16);
    } else if (status == QLatin1String("blocked")) {
        p->setPen(Qt::NoPen);
        p->setBrush(t.warn);
        p->drawEllipse(c, 7, 7);
        p->setPen(QPen(t.onWarn, 1.8, Qt::SolidLine, Qt::RoundCap));
        p->drawLine(QPointF(c.x(), c.y() - 3.5), QPointF(c.x(), c.y() + 0.7));
        p->setPen(Qt::NoPen);
        p->setBrush(t.onWarn);
        p->drawEllipse(QPointF(c.x(), c.y() + 3.3), 1, 1);
    } else if (status == QLatin1String("completed")) {
        p->setPen(Qt::NoPen);
        p->setBrush(Theme::alpha(t.ok, 46));
        p->drawEllipse(c, 7, 7);
        QPainterPath check;
        check.moveTo(c.x() - 3, c.y() + 0.2);
        check.lineTo(c.x() - 1, c.y() + 2.2);
        check.lineTo(c.x() + 3, c.y() - 2);
        p->setPen(QPen(t.ok, 1.8, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p->setBrush(Qt::NoBrush);
        p->drawPath(check);
    } else {
        QPainterPath prompt;
        prompt.moveTo(c.x() - 4.5, c.y() - 3);
        prompt.lineTo(c.x() - 1.5, c.y());
        prompt.lineTo(c.x() - 4.5, c.y() + 3);
        prompt.moveTo(c.x() + 0.5, c.y() + 3.5);
        prompt.lineTo(c.x() + 4.5, c.y() + 3.5);
        p->setPen(QPen(t.faint, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p->setBrush(Qt::NoBrush);
        p->drawPath(prompt);
    }
}

void SidebarDelegate::paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const
{
    // not opt.palette: the sidebar's stylesheet makes the view's background, and so that palette, transparent
    const Theme t = Theme::from(QApplication::palette());
    p->save();
    p->setRenderHint(QPainter::Antialiasing);
    const QRectF r = QRectF(opt.rect).adjusted(8, 1, -8, -1);
    const QString name = index.data(Qt::DisplayRole).toString();

    if (index.data(Kind).toInt() == Workspace) {
        // chevron
        const QPointF c(r.left() + 11, r.center().y());
        QPainterPath chevron;
        if (index.data(Expanded).toBool()) {
            chevron.moveTo(c.x() - 3, c.y() - 1.5);
            chevron.lineTo(c.x(), c.y() + 1.5);
            chevron.lineTo(c.x() + 3, c.y() - 1.5);
        } else {
            chevron.moveTo(c.x() - 1.5, c.y() - 3);
            chevron.lineTo(c.x() + 1.5, c.y());
            chevron.lineTo(c.x() - 1.5, c.y() + 3);
        }
        p->setPen(QPen(t.faint, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p->drawPath(chevron);

        QFont f = opt.font;
        f.setPointSizeF(f.pointSizeF() * 0.82);
        f.setWeight(QFont::DemiBold);
        f.setCapitalization(QFont::AllUppercase);
        f.setLetterSpacing(QFont::PercentageSpacing, 106);
        p->setFont(f);
        const QFontMetricsF fm(f);

        qreal right = r.right() - 6;
        const QString count = QString::number(index.data(Count).toInt());
        p->setPen(t.faint);
        p->drawText(QRectF(right - fm.horizontalAdvance(count), r.top(), fm.horizontalAdvance(count), r.height()), Qt::AlignVCenter, count);
        right -= fm.horizontalAdvance(count) + 8;

        if (const int attention = index.data(Attention).toInt(); attention > 0) {
            const QString a = QString::number(attention);
            const qreal w = qMax<qreal>(16, fm.horizontalAdvance(a) + 10);
            const QRectF pill(right - w, r.center().y() - 8, w, 16);
            p->setPen(Qt::NoPen);
            p->setBrush(Theme::alpha(t.warn, 46));
            p->drawRoundedRect(pill, 8, 8);
            p->setPen(t.warn);
            p->drawText(pill, Qt::AlignCenter, a);
            right -= w + 6;
        }
        p->setPen(t.dim);
        const QRectF label(r.left() + 22, r.top(), right - r.left() - 22, r.height());
        p->drawText(label, Qt::AlignVCenter | Qt::AlignLeft, fm.elidedText(name, Qt::ElideRight, label.width()));
        p->restore();
        return;
    }

    const QString status = index.data(Status).toString();
    const bool loud = status == QLatin1String("blocked") || status == QLatin1String("completed");
    const QRectF pill = r.adjusted(0, 1, 0, -1);
    if (opt.state & QStyle::State_Selected) {
        p->setPen(QPen(Theme::alpha(t.accent, 115), 1));
        p->setBrush(Theme::alpha(t.accent, 40));
        p->drawRoundedRect(pill.adjusted(0.5, 0.5, -0.5, -0.5), 7, 7);
    } else if (opt.state & QStyle::State_MouseOver) {
        p->setPen(Qt::NoPen);
        p->setBrush(Theme::alpha(t.text, 14));
        p->drawRoundedRect(pill, 7, 7);
    }
    drawGlyph(p, QRectF(pill.left() + 10, pill.center().y() - 9, 18, 18), status, t, spinnerPhase);

    const qreal textLeft = pill.left() + 38, textWidth = pill.right() - 8 - textLeft;
    QFont nameFont = opt.font;
    nameFont.setWeight(loud ? QFont::DemiBold : QFont::Medium);
    QFont subFont = opt.font;
    subFont.setPointSizeF(subFont.pointSizeF() * 0.85);
    const QFontMetricsF nfm(nameFont), sfm(subFont);
    const qreal top = pill.center().y() - (nfm.height() + sfm.height() + 1) / 2;
    p->setFont(nameFont);
    p->setPen(t.text);
    p->drawText(QRectF(textLeft, top, textWidth, nfm.height()), Qt::AlignLeft | Qt::AlignVCenter, nfm.elidedText(name, Qt::ElideRight, textWidth));
    p->setFont(subFont);
    p->setPen(status == QLatin1String("idle") ? t.faint : t.statusColor(status));
    p->drawText(QRectF(textLeft, top + nfm.height() + 1, textWidth, sfm.height()), Qt::AlignLeft | Qt::AlignVCenter,
                sfm.elidedText(index.data(Sub).toString(), Qt::ElideMiddle, textWidth));
    p->restore();
}

QSize SidebarDelegate::sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const
{
    const QFontMetrics fm(opt.font);
    return index.data(Kind).toInt() == Workspace ? QSize(200, fm.height() + 14) : QSize(200, fm.height() * 2 + 18);
}
