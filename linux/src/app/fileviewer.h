#pragma once

#include <QPixmap>
#include <QWidget>

class QLabel;

// The built-in read-only viewer for Markdown, text and images.
class FileViewer : public QWidget
{
    Q_OBJECT
public:
    // Shows `path` in a new viewer window; false when the file is not viewable here.
    static bool open(const QString &path, QWidget *parent = nullptr);

protected:
    void resizeEvent(QResizeEvent *event) override;

private:
    explicit FileViewer(const QString &path, QWidget *parent);
    QLabel *m_image = nullptr;
    QPixmap m_pixmap;
};
