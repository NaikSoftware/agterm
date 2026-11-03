#include "filetree.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStringDecoder>

namespace FileTree {

namespace {
QStringList components(const QString &path)
{
    return QDir::cleanPath(path).split(QLatin1Char('/'), Qt::SkipEmptyParts);
}

bool startsWith(const QStringList &list, const QStringList &prefix)
{
    return list.size() >= prefix.size() && std::equal(prefix.begin(), prefix.end(), list.begin());
}

// QFileInfo::suffix reads ".env" as extension "env"; a leading dot is part of the name here.
QString extension(const QString &name)
{
    int start = 0;
    while (start < name.size() && name[start] == QLatin1Char('.'))
        ++start;
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    return dot > start ? name.mid(dot + 1) : QString();
}

QString canonical(const QString &path)
{
    const QString real = QFileInfo(path).canonicalFilePath();
    return real.isEmpty() ? QDir::cleanPath(path) : real;
}

QString join(const QString &dir, const QString &name)
{
    return QDir(dir).filePath(name);
}

bool copyItem(const QString &src, const QString &dst)
{
    const QFileInfo info(src);
    if (info.isSymLink())
        return QFile::link(info.readSymLink(), dst);
    if (!info.isDir())
        return QFile::copy(src, dst);
    if (!QDir().mkdir(dst))
        return false;
    const auto entries = QDir(src).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    return std::all_of(entries.begin(), entries.end(), [&](const QString &e) { return copyItem(join(src, e), join(dst, e)); });
}
}

bool isHidden(const QString &name)
{
    return name == QLatin1String(".DS_Store") || name == QLatin1String(".git");
}

QString copyName(const QString &name, bool isDir, const Exists &exists)
{
    if (!exists(name))
        return name;
    const QString ext = isDir ? QString() : extension(name);
    const QString stem = ext.isEmpty() ? name : name.chopped(ext.size() + 1);
    for (int n = 1;; ++n) {
        const QString candidate = stem + (n == 1 ? QStringLiteral(" copy") : QStringLiteral(" copy %1").arg(n))
            + (ext.isEmpty() ? QString() : QLatin1Char('.') + ext);
        if (!exists(candidate))
            return candidate;
    }
}

bool canMove(const QString &source, const QString &dir)
{
    const QStringList src = components(source), dst = components(dir);
    return !startsWith(dst, src) && dst != src.mid(0, src.size() - 1);
}

QString renameError(const QString &newName, const Exists &exists)
{
    if (newName.trimmed().isEmpty())
        return QStringLiteral("Name cannot be empty.");
    if (newName.contains(QLatin1Char('/')) || newName.contains(QLatin1Char(':')))
        return QStringLiteral("Name cannot contain / or :.");
    if (newName == QLatin1String(".") || newName == QLatin1String(".."))
        return QStringLiteral("Name is reserved.");
    if (exists(newName))
        return QStringLiteral("\"%1\" already exists.").arg(newName);
    return {};
}

QString pasteTarget(const QString &selection, bool isDir, const QString &root)
{
    if (selection.isEmpty())
        return root;
    return isDir ? selection : QFileInfo(selection).absolutePath();
}

QString transferRefusal(const QString &source, const QString &target, bool moving)
{
    const QString name = QFileInfo(source).fileName();
    const QString src = canonical(source), into = canonical(target);
    if (moving) {
        if (!canMove(src, into))
            return QStringLiteral("\"%1\" cannot move into itself or the folder it is already in.").arg(name);
        if (QFileInfo::exists(join(target, name)))
            return QStringLiteral("\"%1\" already exists in \"%2\".").arg(name, QFileInfo(target).fileName());
    } else if (startsWith(components(into), components(src))) {
        return QStringLiteral("\"%1\" cannot be copied into itself.").arg(name);
    }
    return {};
}

QStringList transfer(const QStringList &sources, const QString &target, bool moving, QStringList *results)
{
    QStringList errors;
    for (const QString &source : sources) {
        if (const QString refusal = transferRefusal(source, target, moving); !refusal.isEmpty()) {
            errors << refusal;
            continue;
        }
        const QFileInfo info(source);
        const QString dest = join(target, moving ? info.fileName()
                                                 : copyName(info.fileName(), info.isDir() && !info.isSymLink(),
                                                            [&](const QString &n) { return QFileInfo::exists(join(target, n)); }));
        const bool ok = moving ? QFile::rename(source, dest) : copyItem(source, dest);
        if (!ok)
            errors << QStringLiteral("Could not %1 \"%2\".").arg(moving ? QStringLiteral("move") : QStringLiteral("copy"), info.fileName());
        else if (results)
            *results << dest;
    }
    return errors;
}

QString rename(const QString &path, const QString &newName, QString *dest)
{
    const QFileInfo info(path);
    if (newName == info.fileName())
        return {};
    const QString parent = info.absolutePath();
    if (const QString error = renameError(newName, [&](const QString &n) { return QFileInfo::exists(join(parent, n)); });
        !error.isEmpty())
        return error;
    const QString target = join(parent, newName);
    if (!QFile::rename(path, target))
        return QStringLiteral("Could not rename \"%1\".").arg(info.fileName());
    if (dest)
        *dest = target;
    return {};
}

Viewer viewerFor(const QString &path)
{
    const QString ext = extension(QFileInfo(path).fileName()).toLower();
    static const QStringList markdown{QStringLiteral("md"), QStringLiteral("markdown")};
    static const QStringList images{QStringLiteral("png"), QStringLiteral("jpg"), QStringLiteral("jpeg"), QStringLiteral("gif"),
                                    QStringLiteral("webp")};
    static const QStringList rendered{QStringLiteral("html"), QStringLiteral("htm"), QStringLiteral("xhtml"), QStringLiteral("svg")};
    if (markdown.contains(ext))
        return Viewer::Markdown;
    if (images.contains(ext))
        return Viewer::Image;
    return rendered.contains(ext) ? Viewer::External : Viewer::Text;
}

QString readText(const QString &path)
{
    QFile file(path);
    if (file.size() > (4 << 20) || !file.open(QIODevice::ReadOnly))
        return {};
    const QByteArray data = file.readAll();
    if (data.contains('\0'))
        return {};
    QStringDecoder decoder(QStringDecoder::Utf8, QStringDecoder::Flag::Stateless);
    QString text = decoder(data);
    if (decoder.hasError())
        return {};
    return text.isNull() ? QStringLiteral("") : text;
}
}
