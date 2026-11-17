#include "filepanel.h"
#include "filetree.h"
#include "fileviewer.h"

#include <QAction>
#include <QApplication>
#include <QClipboard>
#include <QDesktopServices>
#include <QDir>
#include <QDrag>
#include <QDropEvent>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemModel>
#include <QFontDatabase>
#include <QHash>
#include <QScrollBar>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMessageBox>
#include <QMimeData>
#include <QPainter>
#include <QSortFilterProxyModel>
#include <QStyledItemDelegate>
#include <QTimer>
#include <QTreeView>
#include <QVBoxLayout>

namespace {
const QString cutMarker = QStringLiteral("application/x-kde-cutselection");

QMimeData *urlMime(const QStringList &paths)
{
    QList<QUrl> urls;
    for (const QString &p : paths)
        urls << QUrl::fromLocalFile(p);
    auto *mime = new QMimeData;
    mime->setUrls(urls);
    return mime;
}

QStringList localPaths(const QMimeData *mime)
{
    QStringList paths;
    if (mime && mime->hasUrls())
        for (const QUrl &url : mime->urls())
            if (url.isLocalFile())
                paths << QDir::cleanPath(url.toLocalFile());
    return paths;
}

class FileProxy : public QSortFilterProxyModel
{
public:
    using QSortFilterProxyModel::QSortFilterProxyModel;
    bool filterAcceptsRow(int row, const QModelIndex &parent) const override
    {
        return !FileTree::isHidden(sourceModel()->index(row, 0, parent).data(QFileSystemModel::FileNameRole).toString());
    }
    // Renames go through FileTree::rename from the delegate, never the model's own setData.
    Qt::ItemFlags flags(const QModelIndex &index) const override { return QSortFilterProxyModel::flags(index) | Qt::ItemIsEditable; }
};
}

class FileDelegate : public QStyledItemDelegate
{
public:
    explicit FileDelegate(FilePanel *panel)
        : QStyledItemDelegate(panel), m_panel(panel)
    {
    }

    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        // QApplication's palette: the view's own has a transparent Highlight so the style draws no selection
        const QPalette pal = QApplication::palette();
        const QString name = index.data(QFileSystemModel::FileNameRole).toString();
        const FileIcons::Icon icon = FileIcons::icon(name, m_panel->isDir(index));
        const bool dark = pal.color(QPalette::Window).lightness() < 128;
        p->save();
        const QRect glyph(opt.rect.left() + 2, opt.rect.center().y() - 8, 16, 16);
        p->setFont(FilePanel::iconFont(icon.font, 14));
        p->setPen(QColor(FileIcons::hex(icon.color, dark)));
        p->drawText(glyph, Qt::AlignCenter, QString::fromUcs4(&icon.glyph, 1));
        QColor text = pal.color(QPalette::WindowText);
        text.setAlphaF(m_panel->m_cut.contains(m_panel->pathOf(index)) ? 0.5 : name.startsWith(QLatin1Char('.')) ? 0.6 : 1);
        p->setPen(text);
        p->setFont(opt.font);
        const QRect label = opt.rect.adjusted(glyph.right() + 7 - opt.rect.left(), 0, -4, 0);
        p->drawText(label, Qt::AlignVCenter | Qt::AlignLeft, opt.fontMetrics.elidedText(name, Qt::ElideRight, label.width()));
        p->restore();
    }

    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &) const override
    {
        return QSize(120, opt.fontMetrics.height() + 16);
    }

    void updateEditorGeometry(QWidget *editor, const QStyleOptionViewItem &opt, const QModelIndex &) const override
    {
        editor->setGeometry(opt.rect.adjusted(22, 2, -4, -2));
    }

    // Selects the name without its extension, like a file manager.
    void setEditorData(QWidget *editor, const QModelIndex &index) const override
    {
        auto *line = qobject_cast<QLineEdit *>(editor);
        const QString name = index.data(QFileSystemModel::FileNameRole).toString();
        line->setText(name);
        const qsizetype dot = m_panel->isDir(index) ? -1 : name.lastIndexOf(QLatin1Char('.'));
        const qsizetype stem = dot > 0 ? dot : name.size();
        QTimer::singleShot(0, line, [line, stem] { line->setSelection(0, int(stem)); });
    }

    void setModelData(QWidget *editor, QAbstractItemModel *, const QModelIndex &index) const override
    {
        m_panel->rename(index, qobject_cast<QLineEdit *>(editor)->text());
    }

private:
    FilePanel *m_panel;
};

class FileTreeView : public QTreeView
{
public:
    explicit FileTreeView(FilePanel *panel)
        : QTreeView(panel), m_panel(panel)
    {
    }

protected:
    void drawRow(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        const QPalette pal = QApplication::palette();
        QColor fill;
        if (index == m_dropRow) {
            fill = pal.color(QPalette::Highlight);
            fill.setAlphaF(0.3);
        } else if (selectionModel()->isSelected(index)) {
            fill = pal.color(QPalette::Highlight);
            fill.setAlpha(hasFocus() ? 110 : 80);
        } else if (const QPoint cursor = viewport()->mapFromGlobal(QCursor::pos());
                   viewport()->rect().contains(cursor) && indexAt(cursor).siblingAtColumn(0) == index) {
            fill = pal.color(QPalette::WindowText);
            fill.setAlpha(16);
        }
        if (fill.isValid()) {
            p->save();
            p->setRenderHint(QPainter::Antialiasing);
            p->setPen(Qt::NoPen);
            p->setBrush(fill);
            p->drawRoundedRect(QRectF(opt.rect).adjusted(6, 1, -6, -1), 6, 6);
            p->restore();
        }
        QTreeView::drawRow(p, opt, index);
    }

    void keyPressEvent(QKeyEvent *event) override
    {
        if ((event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) && state() != EditingState
            && !(event->modifiers() & ~Qt::KeypadModifier)) {
            for (const QModelIndex &index : selectionModel()->selectedRows())
                m_panel->open(index);
            return;
        }
        QTreeView::keyPressEvent(event);
    }

    // A selected item inside a selected folder travels with the folder. Copy is the default for other apps;
    // the result is ignored so Qt never removes rows from the model after a move.
    void startDrag(Qt::DropActions) override
    {
        const QStringList paths = m_panel->topLevelSelection();
        if (paths.isEmpty() || state() == EditingState)
            return;
        auto *drag = new QDrag(this);
        drag->setMimeData(urlMime(paths));
        drag->exec(Qt::CopyAction | Qt::MoveAction, Qt::CopyAction);
    }

    void dragEnterEvent(QDragEnterEvent *event) override { dragMoveEvent(event); }

    void dragMoveEvent(QDragMoveEvent *event) override
    {
        const QModelIndex target = dropFolder(event->position().toPoint());
        const QString dir = target.isValid() ? m_panel->pathOf(target) : m_panel->m_root;
        const bool moving = moves(event);
        const QStringList sources = localPaths(event->mimeData());
        const bool ok = std::any_of(sources.begin(), sources.end(),
                                    [&](const QString &s) { return FileTree::transferRefusal(s, dir, moving).isEmpty(); });
        setDropRow(ok ? target : QModelIndex());
        if (!ok || !(event->possibleActions() & (moving ? Qt::MoveAction : Qt::CopyAction)))
            return event->ignore();
        event->setDropAction(moving ? Qt::MoveAction : Qt::CopyAction);
        event->accept();
        if (hasAutoScroll())
            startAutoScroll();
    }

    void dragLeaveEvent(QDragLeaveEvent *) override { setDropRow({}); }

    // The model is read-only and never handles drops: transfer refuses overwrites and names copies.
    void dropEvent(QDropEvent *event) override
    {
        const QModelIndex target = dropFolder(event->position().toPoint());
        setDropRow({});
        const QStringList sources = localPaths(event->mimeData());
        if (sources.isEmpty() || m_panel->m_root.isEmpty())
            return event->ignore();
        const bool moving = moves(event);
        event->setDropAction(moving ? Qt::MoveAction : Qt::CopyAction);
        event->accept();
        m_panel->transfer(sources, target.isValid() ? m_panel->pathOf(target) : m_panel->m_root, moving);
    }

private:
    // Ctrl copies inside the panel; a drag from another app always copies.
    bool moves(const QDropEvent *event) const
    {
        return event->source() == this && !(event->modifiers() & Qt::ControlModifier);
    }

    // A folder row itself, a file row's folder, or invalid for the root.
    QModelIndex dropFolder(const QPoint &pos) const
    {
        QModelIndex index = indexAt(pos).siblingAtColumn(0);
        if (index.isValid() && !m_panel->isDir(index))
            index = index.parent();
        return index == rootIndex() ? QModelIndex() : index;
    }

    void setDropRow(const QModelIndex &index)
    {
        if (m_dropRow == index)
            return;
        m_dropRow = index;
        viewport()->update();
    }

    FilePanel *m_panel;
    QPersistentModelIndex m_dropRow;
};

QFont FilePanel::iconFont(FileIcons::Font font, int pixelSize)
{
    static const QHash<FileIcons::Font, QString> families = [] {
        QHash<FileIcons::Font, QString> map;
        for (auto f : {FileIcons::Font::FileIcons, FileIcons::Font::Devopicons, FileIcons::Font::Mfixx, FileIcons::Font::FontAwesome}) {
            QFile file(FileIcons::fontFile(f));
            const int id = file.open(QIODevice::ReadOnly) ? QFontDatabase::addApplicationFontFromData(file.readAll()) : -1;
            map.insert(f, QFontDatabase::applicationFontFamilies(id).value(0, FileIcons::family(f)));
        }
        return map;
    }();
    QFont f(families.value(font));
    f.setPixelSize(pixelSize);
    // Some glyphs are plain code points ('y' for YAML); never draw them from a fallback font.
    f.setStyleStrategy(QFont::NoFontMerging);
    return f;
}

FilePanel::FilePanel(QWidget *parent)
    : QWidget(parent)
    , m_header(new QLabel(this))
    , m_empty(new QLabel(this))
    , m_view(new FileTreeView(this))
{
    Q_INIT_RESOURCE(fileicons); // the fonts live in a static library, which the linker would otherwise drop
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    QFont headerFont = m_header->font();
    headerFont.setWeight(QFont::Medium);
    m_header->setFont(headerFont);
    m_header->setContentsMargins(12, 4, 12, 4);
    m_empty->setAlignment(Qt::AlignCenter);
    m_empty->setText(QStringLiteral("No folder"));
    layout->addWidget(m_header);
    layout->addWidget(m_empty, 1);
    layout->addWidget(m_view, 1);

    m_view->setItemDelegate(new FileDelegate(this));
    m_view->setHeaderHidden(true);
    m_view->setFrameShape(QFrame::NoFrame);
    m_view->setIndentation(14);
    m_view->setUniformRowHeights(true);
    m_view->setExpandsOnDoubleClick(false);
    m_view->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_view->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_view->setContextMenuPolicy(Qt::CustomContextMenu);
    m_view->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_view->setDragEnabled(true);
    m_view->setAcceptDrops(true);
    m_view->setDropIndicatorShown(false);
    m_view->setDragDropMode(QAbstractItemView::DragDrop);
    m_view->viewport()->setAcceptDrops(true);
    m_view->viewport()->setAttribute(Qt::WA_Hover);
    applyPalette();

    // A single click only selects: opening on it would break drag and multi-select.
    connect(m_view, &QTreeView::doubleClicked, this, &FilePanel::open);
    connect(m_view, &QWidget::customContextMenuRequested, this, &FilePanel::showMenu);
    connect(&m_rootWatcher, &QFileSystemWatcher::directoryChanged, this, &FilePanel::updateState);
    connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this, &FilePanel::clipboardChanged);

    auto action = [this](const QString &text, const QKeySequence &key, auto slot) {
        auto *a = new QAction(text, m_view);
        a->setShortcut(key);
        a->setShortcutContext(Qt::WidgetShortcut);
        connect(a, &QAction::triggered, this, slot);
        m_view->addAction(a);
        return a;
    };
    m_cutAction = action(QStringLiteral("Cut"), QKeySequence::Cut, [this] { writeClipboard(true); });
    m_copyAction = action(QStringLiteral("Copy"), QKeySequence::Copy, [this] { writeClipboard(false); });
    m_pasteAction = action(QStringLiteral("Paste"), QKeySequence::Paste, &FilePanel::paste);
    m_trashAction = action(QStringLiteral("Move to Trash"), QKeySequence::Delete, &FilePanel::trash);
    updateState();
}

void FilePanel::setRoot(const QString &dir)
{
    if (dir == m_root)
        return;
    // remember where the user was in the folder being left, to come back to it
    if (m_proxy && !m_root.isEmpty()) {
        QStringList expanded;
        for (QModelIndex i = m_view->indexAt(QPoint(0, 0)); i.isValid(); i = m_view->indexBelow(i))
            if (m_view->isExpanded(i))
                expanded << pathOf(i);
        m_views.insert(m_root, {expanded, m_view->verticalScrollBar()->value()});
    }
    m_root = dir;
    m_cut.clear();
    if (!m_rootWatcher.directories().isEmpty())
        m_rootWatcher.removePaths(m_rootWatcher.directories());
    if (!m_model) {
        // one model for the panel's life: switching folders moves its root and reuses what it already loaded,
        // instead of a fresh model refilling an empty tree on every session switch
        m_model = new QFileSystemModel(this);
        m_model->setOption(QFileSystemModel::DontUseCustomDirectoryIcons);
        m_model->setFilter(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
        m_model->sort(0); // its own sorter: folders first, natural order
        m_proxy = new FileProxy(this);
        m_proxy->setSourceModel(m_model);
        m_view->setModel(m_proxy);
        for (int c = 1; c < m_model->columnCount(); ++c)
            m_view->hideColumn(c);
    }
    if (!dir.isEmpty() && QFileInfo(dir).isDir()) {
        m_rootWatcher.addPath(dir);
        m_model->setRootPath(dir);
        m_view->setRootIndex(m_proxy->mapFromSource(m_model->index(dir)));
        m_view->collapseAll();
        const View saved = m_views.value(dir);
        for (const QString &path : saved.expanded)
            m_view->expand(indexOf(path));
        QTimer::singleShot(0, m_view, [this, scroll = saved.scroll] { m_view->verticalScrollBar()->setValue(scroll); });
    }
    m_header->setText(QFileInfo(dir).fileName().isEmpty() ? dir : QFileInfo(dir).fileName());
    m_header->setToolTip(dir);
    updateState();
}

void FilePanel::updateState()
{
    const QFileInfo info(m_root);
    QString message;
    if (m_root.isEmpty())
        message = QStringLiteral("No folder");
    else if (!info.isDir())
        message = QStringLiteral("Folder not found");
    else if (!info.isReadable() || !info.isExecutable())
        message = QStringLiteral("Cannot read this folder");
    m_empty->setText(message);
    m_empty->setVisible(!message.isEmpty());
    m_view->setVisible(message.isEmpty());
    m_header->setVisible(!m_root.isEmpty());
}

void FilePanel::changeEvent(QEvent *event)
{
    QWidget::changeEvent(event);
    if (event->type() == QEvent::ApplicationPaletteChange)
        applyPalette();
}

void FilePanel::applyPalette()
{
    QPalette pal = QApplication::palette();
    pal.setColor(QPalette::Highlight, Qt::transparent);
    pal.setColor(QPalette::HighlightedText, pal.color(QPalette::WindowText));
    m_view->setPalette(pal);
    QColor dim = QApplication::palette().color(QPalette::WindowText);
    dim.setAlphaF(0.6);
    QPalette labels = QApplication::palette();
    labels.setColor(QPalette::WindowText, dim);
    m_header->setPalette(labels);
    m_empty->setPalette(labels);
}

QString FilePanel::pathOf(const QModelIndex &index) const
{
    return m_proxy && index.isValid() ? m_model->filePath(m_proxy->mapToSource(index)) : QString();
}

bool FilePanel::isDir(const QModelIndex &index) const
{
    return m_proxy && m_model->isDir(m_proxy->mapToSource(index));
}

QModelIndex FilePanel::indexOf(const QString &path) const
{
    return m_proxy ? m_proxy->mapFromSource(m_model->index(path)) : QModelIndex();
}

QStringList FilePanel::topLevelSelection() const
{
    QStringList paths, dirs;
    const QModelIndexList rows = m_view->selectionModel() ? m_view->selectionModel()->selectedRows() : QModelIndexList();
    for (const QModelIndex &index : rows)
        if (isDir(index))
            dirs << pathOf(index) + QLatin1Char('/');
    for (const QModelIndex &index : rows) {
        const QString path = pathOf(index);
        if (std::none_of(dirs.begin(), dirs.end(), [&](const QString &d) { return path.startsWith(d); }))
            paths << path;
    }
    return paths;
}

QString FilePanel::pasteTarget() const
{
    const QModelIndexList rows = m_view->selectionModel() ? m_view->selectionModel()->selectedRows() : QModelIndexList();
    return rows.isEmpty() ? m_root : FileTree::pasteTarget(pathOf(rows.first()), isDir(rows.first()), m_root);
}

bool FilePanel::canPaste() const
{
    return m_proxy && !localPaths(QGuiApplication::clipboard()->mimeData()).isEmpty();
}

// Toggles a folder; shows a file in the built-in viewer when it can, else hands it to its default app.
void FilePanel::open(const QModelIndex &index)
{
    if (!index.isValid())
        return;
    if (isDir(index)) {
        m_view->setExpanded(index, !m_view->isExpanded(index));
        return;
    }
    const QString path = pathOf(index);
    if (!FileViewer::open(path, window()))
        QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

void FilePanel::openWithDefaultApp()
{
    for (const QModelIndex &index : m_view->selectionModel()->selectedRows())
        QDesktopServices::openUrl(QUrl::fromLocalFile(pathOf(index)));
}

void FilePanel::writeClipboard(bool cut)
{
    const QStringList paths = topLevelSelection();
    if (paths.isEmpty())
        return;
    QMimeData *mime = urlMime(paths);
    if (cut)
        mime->setData(cutMarker, "1");
    m_cut = cut ? QSet<QString>(paths.begin(), paths.end()) : QSet<QString>();
    QGuiApplication::clipboard()->setMimeData(mime);
    m_view->viewport()->update();
}

// Cut items stay dimmed only while the clipboard still holds that cut.
void FilePanel::clipboardChanged()
{
    if (m_cut.isEmpty())
        return;
    const QMimeData *mime = QGuiApplication::clipboard()->mimeData();
    const QStringList paths = localPaths(mime);
    if (mime && mime->data(cutMarker) == "1" && QSet<QString>(paths.begin(), paths.end()) == m_cut)
        return;
    m_cut.clear();
    m_view->viewport()->update();
}

// Moves a cut (ours or a KDE file manager's), copies anything else, into the selected folder or the root.
void FilePanel::paste()
{
    if (!m_proxy)
        return;
    QClipboard *clipboard = QGuiApplication::clipboard();
    const QMimeData *mime = clipboard->mimeData();
    const QStringList sources = localPaths(mime);
    if (sources.isEmpty())
        return;
    const bool moving = mime->data(cutMarker) == "1";
    // A cut pastes once: the sources are gone afterwards.
    if (moving)
        clipboard->clear();
    transfer(sources, pasteTarget(), moving);
}

void FilePanel::trash()
{
    QStringList errors;
    for (const QString &path : topLevelSelection())
        if (!QFile::moveToTrash(path))
            errors << QStringLiteral("Could not move \"%1\" to the Trash.").arg(QFileInfo(path).fileName());
    showErrors(errors);
}

void FilePanel::rename(const QModelIndex &index, const QString &newName)
{
    QString dest;
    const QString error = FileTree::rename(pathOf(index), newName, &dest);
    if (!error.isEmpty())
        showErrors({error});
    else if (!dest.isEmpty())
        select({dest});
}

void FilePanel::transfer(const QStringList &sources, const QString &target, bool moving)
{
    QStringList results;
    const QStringList errors = FileTree::transfer(sources, target, moving, &results);
    if (!results.isEmpty() && QDir::cleanPath(target) != QDir::cleanPath(m_root))
        m_view->expand(indexOf(target));
    select(results);
    showErrors(errors);
}

void FilePanel::select(const QStringList &paths)
{
    QItemSelection selection;
    for (const QString &path : paths)
        if (const QModelIndex index = indexOf(path); index.isValid())
            selection.select(index, index);
    if (selection.isEmpty())
        return;
    m_view->selectionModel()->select(selection, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
    m_view->selectionModel()->setCurrentIndex(selection.indexes().first(), QItemSelectionModel::NoUpdate);
    m_view->scrollTo(selection.indexes().first());
}

// One dialog for a whole operation, never one per item.
void FilePanel::showErrors(const QStringList &errors)
{
    if (errors.isEmpty())
        return;
    auto *box = new QMessageBox(QMessageBox::Warning, QStringLiteral("File panel"),
                                errors.size() == 1 ? errors.first() : QStringLiteral("Some items were skipped."), QMessageBox::Ok, this);
    if (errors.size() > 1)
        box->setInformativeText(errors.join(QLatin1Char('\n')));
    box->setAttribute(Qt::WA_DeleteOnClose);
    box->open();
}

void FilePanel::showMenu(const QPoint &pos)
{
    if (!m_proxy)
        return;
    const QModelIndex index = m_view->indexAt(pos).siblingAtColumn(0);
    if (!index.isValid())
        m_view->clearSelection();
    else if (!m_view->selectionModel()->isRowSelected(index.row(), index.parent()))
        m_view->selectionModel()->setCurrentIndex(index, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
    QMenu menu(this);
    const QString path = pathOf(index);
    const QString here = !index.isValid() ? m_root : isDir(index) ? path : QFileInfo(path).absolutePath();
    m_pasteAction->setEnabled(canPaste());
    if (index.isValid()) {
        menu.addAction(QStringLiteral("Open"), this, [this] {
            for (const QModelIndex &i : m_view->selectionModel()->selectedRows())
                open(i);
        });
        menu.addAction(QStringLiteral("Open with Default App"), this, &FilePanel::openWithDefaultApp);
        menu.addSeparator();
        menu.addAction(QStringLiteral("New Companion Here"), this, [this, here] { Q_EMIT companionRequested(here); });
        menu.addSeparator();
        menu.addActions({m_cutAction, m_copyAction, m_pasteAction});
        menu.addSeparator();
        QAction *rename = menu.addAction(QStringLiteral("Rename…"), this, [this, row = QPersistentModelIndex(index)] { m_view->edit(row); });
        rename->setEnabled(m_view->selectionModel()->selectedRows().size() == 1);
        menu.addAction(m_trashAction);
    } else {
        menu.addAction(QStringLiteral("New Companion Here"), this, [this, here] { Q_EMIT companionRequested(here); });
        menu.addAction(m_pasteAction);
    }
    menu.exec(m_view->viewport()->mapToGlobal(pos));
    m_pasteAction->setEnabled(true);
}
