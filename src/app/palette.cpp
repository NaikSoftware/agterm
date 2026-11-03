#include "palette.h"

#include <QApplication>
#include <QKeyEvent>
#include <QLineEdit>
#include <QListWidget>
#include <QPainter>
#include <QStyledItemDelegate>
#include <QVBoxLayout>

namespace {
enum { SubtitleRole = Qt::UserRole + 1, IndexRole };

class RowDelegate : public QStyledItemDelegate
{
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        const QPalette pal = QApplication::palette();
        p->save();
        p->setRenderHint(QPainter::Antialiasing);
        const QRectF r = QRectF(opt.rect).adjusted(6, 1, -6, -1);
        if (opt.state & QStyle::State_Selected) {
            QColor sel = pal.color(QPalette::Highlight);
            sel.setAlpha(110);
            p->setPen(Qt::NoPen);
            p->setBrush(sel);
            p->drawRoundedRect(r, 6, 6);
        }
        QColor text = pal.color(QPalette::WindowText);
        if (!(index.flags() & Qt::ItemIsEnabled))
            text.setAlpha(110);
        QColor dim = text;
        dim.setAlpha(text.alpha() * 150 / 255);
        QFont small = opt.font;
        small.setPointSizeF(small.pointSizeF() * 0.85);
        const QFontMetrics fm(opt.font), sfm(small);
        const QString sub = index.data(SubtitleRole).toString();
        const qreal top = r.center().y() - (fm.height() + (sub.isEmpty() ? 0 : sfm.height())) / 2.0;
        p->setPen(text);
        p->setFont(opt.font);
        p->drawText(QRectF(r.left() + 12, top, r.width() - 24, fm.height()), Qt::AlignVCenter,
                    fm.elidedText(index.data().toString(), Qt::ElideRight, int(r.width() - 24)));
        if (!sub.isEmpty()) {
            p->setPen(dim);
            p->setFont(small);
            p->drawText(QRectF(r.left() + 12, top + fm.height(), r.width() - 24, sfm.height()), Qt::AlignVCenter,
                        sfm.elidedText(sub, Qt::ElideMiddle, int(r.width() - 24)));
        }
        p->restore();
    }
    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        const int sub = index.data(SubtitleRole).toString().isEmpty() ? 0 : opt.fontMetrics.height();
        return QSize(200, opt.fontMetrics.height() + sub + 14);
    }
};
} // namespace

Palette::Palette(QWidget *window)
    : QFrame(window)
{
    setObjectName(QStringLiteral("palette"));
    const QPalette pal = QApplication::palette();
    QColor border = pal.color(QPalette::WindowText);
    border.setAlpha(40);
    setStyleSheet(QStringLiteral("#palette{background:%1;border:1px solid %2;border-radius:10px;}"
                                 "QLineEdit{border:none;background:transparent;padding:10px 12px;font-size:%3pt;}"
                                 "QListWidget{border:none;background:transparent;}")
                      .arg(pal.color(QPalette::Window).name(), border.name(QColor::HexArgb))
                      .arg(font().pointSizeF() * 1.1));
    m_search = new QLineEdit;
    m_search->addAction(QIcon::fromTheme(QStringLiteral("search")), QLineEdit::LeadingPosition);
    m_list = new QListWidget;
    m_list->setItemDelegate(new RowDelegate(m_list));
    m_list->setFocusPolicy(Qt::NoFocus);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    auto *col = new QVBoxLayout(this);
    col->setContentsMargins(4, 4, 4, 6);
    col->setSpacing(2);
    col->addWidget(m_search);
    col->addWidget(m_list);
    connect(m_search, &QLineEdit::textChanged, this, &Palette::filter);
    connect(m_list, &QListWidget::itemClicked, this, &Palette::runCurrent);
    connect(m_list, &QListWidget::currentItemChanged, this, [this](QListWidgetItem *row) {
        if (row && isVisible())
            if (const auto &preview = m_items[row->data(IndexRole).toInt()].preview)
                preview();
    });
    m_search->installEventFilter(this);
    qApp->installEventFilter(this); // Ctrl release ends the switcher; a click elsewhere dismisses
    hide();
}

bool Palette::fuzzyMatch(const QString &needle, const QString &haystack)
{
    int at = 0;
    for (const QChar c : needle) {
        if (c.isSpace())
            continue;
        at = haystack.indexOf(c, at, Qt::CaseInsensitive);
        if (at < 0)
            return false;
        ++at;
    }
    return true;
}

void Palette::open(const QString &placeholder, const QList<Item> &items, bool switcher, std::function<void()> cancel, int current)
{
    m_items = items;
    m_switcher = switcher;
    m_cancel = std::move(cancel);
    m_initial = current;
    m_search->setPlaceholderText(placeholder);
    m_search->setVisible(!switcher);
    m_search->clear();
    filter();
    m_initial = -1;
    place();
    show();
    raise();
    m_search->setFocus();
}

void Palette::place()
{
    QWidget *w = parentWidget();
    const int width = qBound(420, w->width() * 2 / 5, 760);
    int rows = 0;
    for (int i = 0; i < m_list->count() && i < 9; ++i)
        rows += m_list->sizeHintForRow(i);
    const int height = (m_switcher ? 0 : m_search->sizeHint().height()) + rows + 20;
    setGeometry((w->width() - width) / 2, w->height() / 6, width, qMin(height, w->height() * 2 / 3));
}

void Palette::filter()
{
    m_list->clear();
    const QString needle = m_search->text();
    for (int i = 0; i < m_items.size(); ++i) {
        const Item &it = m_items[i];
        if (!fuzzyMatch(needle, it.title + QLatin1Char(' ') + it.subtitle))
            continue;
        auto *row = new QListWidgetItem(it.title, m_list);
        row->setData(SubtitleRole, it.subtitle);
        row->setData(IndexRole, i);
        if (!it.enabled)
            row->setFlags(row->flags() & ~Qt::ItemIsEnabled);
    }
    int row = m_switcher && m_list->count() > 1 ? 1 : 0; // a single Ctrl-Tab tap flips back
    for (int i = 0; m_initial >= 0 && i < m_list->count(); ++i)
        if (m_list->item(i)->data(IndexRole).toInt() == m_initial)
            row = i;
    m_list->setCurrentRow(row);
    if (isVisible())
        place();
}

void Palette::step(int delta)
{
    if (const int n = m_list->count())
        m_list->setCurrentRow((m_list->currentRow() + delta + n) % n);
}

void Palette::runCurrent()
{
    QListWidgetItem *row = m_list->currentItem();
    m_cancel = {};
    hide();
    if (row && (row->flags() & Qt::ItemIsEnabled))
        if (const auto &run = m_items[row->data(IndexRole).toInt()].run)
            run();
}

bool Palette::eventFilter(QObject *watched, QEvent *event)
{
    if (!isVisible())
        return false;
    if (event->type() == QEvent::KeyRelease && m_switcher && static_cast<QKeyEvent *>(event)->key() == Qt::Key_Control) {
        runCurrent();
        return true;
    }
    if (event->type() == QEvent::MouseButtonPress && !isAncestorOf(qobject_cast<QWidget *>(watched)) && watched != this) {
        dismiss();
        return false;
    }
    if (event->type() != QEvent::KeyPress || (watched != m_search && !m_switcher))
        return false;
    auto *key = static_cast<QKeyEvent *>(event);
    const bool ctrl = key->modifiers() & Qt::ControlModifier;
    switch (key->key()) {
    case Qt::Key_Escape:
        dismiss();
        return true;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        runCurrent();
        return true;
    case Qt::Key_Down:
        step(1);
        return true;
    case Qt::Key_Up:
        step(-1);
        return true;
    case Qt::Key_Tab:
        if (m_switcher)
            step(1);
        return m_switcher;
    case Qt::Key_Backtab:
        if (m_switcher)
            step(-1);
        return m_switcher;
    case Qt::Key_J:
    case Qt::Key_K:
        if (!ctrl)
            return false;
        step(key->key() == Qt::Key_J ? 1 : -1);
        return true;
    default:
        return m_switcher; // the switcher swallows keys while Ctrl is held
    }
}

void Palette::dismiss()
{
    hide();
    if (auto cancel = std::exchange(m_cancel, {}))
        cancel();
}
