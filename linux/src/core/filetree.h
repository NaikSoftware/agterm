#pragma once

#include <QStringList>
#include <functional>

// The file panel's file rules: Finder-style copy names, moves and renames that never overwrite, viewer choice.
namespace FileTree {
using Exists = std::function<bool(const QString &name)>;

bool isHidden(const QString &name);
// "name.ext", then "name copy.ext", "name copy 2.ext", ...; folders and dotfiles append to the whole name.
QString copyName(const QString &name, bool isDir, const Exists &exists);
// False for the folder itself, one of its descendants, or the folder it already is in.
bool canMove(const QString &source, const QString &dir);
// Empty when the name is valid.
QString renameError(const QString &newName, const Exists &exists);
QString pasteTarget(const QString &selection, bool isDir, const QString &root);

// Why `source` cannot go into `target`; empty when it can.
QString transferRefusal(const QString &source, const QString &target, bool moving);
// Moves, or copies under copyName, never over an existing item; returns the error per skipped item.
QStringList transfer(const QStringList &sources, const QString &target, bool moving, QStringList *results = nullptr);
QString rename(const QString &path, const QString &newName, QString *dest = nullptr);

enum class Viewer { Markdown, Image, Text, External };
// By extension; Text means "try it", since readText then refuses a binary or oversized file.
Viewer viewerFor(const QString &path);
// The file's text, or a null string when it is over 4 MiB, holds a NUL, or is not valid UTF-8.
QString readText(const QString &path);
}
