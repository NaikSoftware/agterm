#include "fileviewer.h"
#include "filetree.h"

#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QLabel>
#include <QPlainTextEdit>
#include <QShortcut>
#include <QTextBrowser>
#include <QUrl>
#include <QVBoxLayout>

bool FileViewer::open(const QString &path, QWidget *parent)
{
    QWidget *content = nullptr;
    QPixmap pixmap;
    switch (FileTree::viewerFor(path)) {
    case FileTree::Viewer::Markdown: {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly))
            return false;
        auto *browser = new QTextBrowser;
        browser->document()->setBaseUrl(QUrl::fromLocalFile(QFileInfo(path).absolutePath() + QLatin1Char('/')));
        browser->setOpenExternalLinks(true);
        browser->setMarkdown(QString::fromUtf8(file.readAll()));
        content = browser;
        break;
    }
    case FileTree::Viewer::Image:
        if (!pixmap.load(path))
            return false;
        break;
    case FileTree::Viewer::Text: {
        const QString text = FileTree::readText(path);
        if (text.isNull())
            return false;
        auto *edit = new QPlainTextEdit(text);
        edit->setReadOnly(true);
        edit->setLineWrapMode(QPlainTextEdit::NoWrap);
        edit->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
        content = edit;
        break;
    }
    case FileTree::Viewer::External:
        return false;
    }
    auto *viewer = new FileViewer(path, parent);
    if (content) {
        viewer->layout()->addWidget(content);
    } else {
        viewer->m_pixmap = pixmap;
        viewer->m_image = new QLabel;
        viewer->m_image->setAlignment(Qt::AlignCenter);
        viewer->m_image->setMinimumSize(1, 1);
        viewer->layout()->addWidget(viewer->m_image);
        viewer->resize(pixmap.size().boundedTo(QSize(1200, 900)).expandedTo(QSize(320, 240)));
    }
    viewer->show();
    return true;
}

FileViewer::FileViewer(const QString &path, QWidget *parent)
    : QWidget(parent, Qt::Window)
{
    setAttribute(Qt::WA_DeleteOnClose);
    setWindowTitle(QFileInfo(path).fileName());
    setWindowFilePath(path);
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    resize(860, 680);
    new QShortcut(Qt::Key_Escape, this, this, &QWidget::close);
}

void FileViewer::resizeEvent(QResizeEvent *event)
{
    QWidget::resizeEvent(event);
    if (!m_image)
        return;
    // Shown at its own size in logical pixels, shrunk to fit but never enlarged.
    const qreal dpr = devicePixelRatioF();
    QPixmap px = m_pixmap.scaled(m_pixmap.size().boundedTo(m_image->size()) * dpr, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    px.setDevicePixelRatio(dpr);
    m_image->setPixmap(px);
}
