#pragma once

#include <QString>

// Atom file-icons: which bundled font glyph, in which Atom hue, a file shows.
namespace FileIcons {
enum class Font { FileIcons, Devopicons, Mfixx, FontAwesome };
enum class Color { Red, Orange, Yellow, Green, Cyan, Blue, Purple, Pink, Grey };

struct Icon {
    Font font;
    char32_t glyph;
    Color color;
    bool operator==(const Icon &) const = default;
};

// The font's family name once its bundled TTF is registered.
QString family(Font font);
QString fontFile(Font font);
// Atom's medium-* on a dark background, dark-* on a light one.
QString hex(Color color, bool dark);
Icon icon(const QString &name, bool isDirectory);
}
