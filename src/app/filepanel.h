#pragma once

#include "fileicons.h"

#include <QFileSystemWatcher>
#include <QSet>
#include <QWidget>

class QAction;
class QFileSystemModel;
class QLabel;
class QSortFilterProxyModel;
class FileTreeView;

// The file panel: the active session's folder as a live tree with open, clipboard, rename, trash and drag and drop.
class FilePanel : public QWidget
{
    Q_OBJECT
public:
    explicit FilePanel(QWidget *parent = nullptr);
    // No-op when unchanged; an empty dir shows "No folder".
    void setRoot(const QString &dir);
    QString root() const { return m_root; }
    // The registered bundled font a file-icons glyph draws with.
    static QFont iconFont(FileIcons::Font font, int pixelSize);

Q_SIGNALS:
    void companionRequested(const QString &dir);

protected:
    void changeEvent(QEvent *event) override;

private:
    friend class FileTreeView;
    friend class FileDelegate;

    QString pathOf(const QModelIndex &index) const;
    bool isDir(const QModelIndex &index) const;
    QModelIndex indexOf(const QString &path) const;
    QStringList topLevelSelection() const;
    QString pasteTarget() const;
    bool canPaste() const;
    void open(const QModelIndex &index);
    void openWithDefaultApp();
    void writeClipboard(bool cut);
    void clipboardChanged();
    void paste();
    void trash();
    void rename(const QModelIndex &index, const QString &newName);
    void transfer(const QStringList &sources, const QString &target, bool moving);
    void select(const QStringList &paths);
    void showErrors(const QStringList &errors);
    void showMenu(const QPoint &pos);
    void updateState();
    void applyPalette();

    QString m_root;
    QLabel *m_header;
    QLabel *m_empty;
    FileTreeView *m_view;
    QFileSystemModel *m_model = nullptr;
    QSortFilterProxyModel *m_proxy = nullptr;
    QFileSystemWatcher m_rootWatcher;
    QSet<QString> m_cut;
    QAction *m_cutAction, *m_copyAction, *m_pasteAction, *m_trashAction;
};
