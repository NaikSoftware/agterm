#include "fileicons.h"

#include <QHash>
#include <QList>
#include <QPair>

namespace FileIcons {

QString family(Font font)
{
    switch (font) {
    case Font::FileIcons: return QStringLiteral("file-icons");
    case Font::Devopicons: return QStringLiteral("DevOpicons");
    case Font::Mfixx: return QStringLiteral("MFixx");
    case Font::FontAwesome: return QStringLiteral("FontAwesome");
    }
    return {};
}

QString fontFile(Font font)
{
    return font == Font::FontAwesome ? QStringLiteral(":/file-icons/fontawesome-webfont.ttf")
                                     : QStringLiteral(":/file-icons/%1.ttf").arg(family(font));
}

QString hex(Color color, bool dark)
{
    switch (color) {
    case Color::Red: return QLatin1String(dark ? "#ac4142" : "#742c2d");
    case Color::Orange: return QLatin1String(dark ? "#d28445" : "#a35f27");
    case Color::Yellow: return QLatin1String(dark ? "#f4bf75" : "#ee9e2e");
    case Color::Green: return QLatin1String(dark ? "#90a959" : "#66783e");
    case Color::Cyan: return QLatin1String(dark ? "#75b5aa" : "#4d9085");
    case Color::Blue: return QLatin1String(dark ? "#6a9fb5" : "#46788d");
    case Color::Purple: return QLatin1String(dark ? "#aa759f" : "#825078");
    case Color::Pink: return QLatin1String(dark ? "#ff00cc" : "#b2008f");
    case Color::Grey: return QLatin1String(dark ? "#7f7f7f" : "#595959");
    }
    return {};
}

namespace {
using F = Font;
using C = Color;
constexpr Icon folder{F::FontAwesome, 0xF07B, C::Grey};
constexpr Icon file{F::FontAwesome, 0xF016, C::Grey};
constexpr Icon lock{F::FontAwesome, 0xF023, C::Grey};
constexpr Icon npm{F::FileIcons, 0xE91C, C::Red};
constexpr Icon git{F::Devopicons, 0xE602, C::Red};
constexpr Icon swift{F::Devopicons, 0xE655, C::Orange};
// Atom's dotenv glyph U+EBB8 is missing from the shipped font; config is the nearest.
constexpr Icon dotenv{F::FileIcons, 0xF07C, C::Yellow};
constexpr Icon book{F::FontAwesome, 0xF02D, C::Blue};
constexpr Icon yaml{F::FileIcons, 0x79, C::Red};
constexpr Icon shell{F::FileIcons, 0xF0C8, C::Purple};
constexpr Icon markdown{F::Devopicons, 0xE63E, C::Blue};

const QHash<QString, Icon> names{
    {QStringLiteral("dockerfile"), {F::FileIcons, 0xF106, C::Blue}},
    {QStringLiteral("makefile"), {F::FontAwesome, 0xF0AE, C::Yellow}},
    {QStringLiteral("package.json"), npm},
    {QStringLiteral("package-lock.json"), npm},
    {QStringLiteral("package.swift"), swift},
    {QStringLiteral("yarn.lock"), {F::FileIcons, 0xEA1A, C::Blue}},
    {QStringLiteral(".gitignore"), git},
    {QStringLiteral(".gitattributes"), git},
    {QStringLiteral(".gitmodules"), git},
    {QStringLiteral(".env"), dotenv},
};

const QList<QPair<QString, Icon>> prefixes{
    {QStringLiteral("readme"), book},
    {QStringLiteral("license"), book},
    {QStringLiteral("licence"), book},
    {QStringLiteral(".env."), dotenv},
};

const QHash<QString, Icon> extensions{
    {QStringLiteral("swift"), swift},
    {QStringLiteral("js"), {F::Mfixx, 0xF129, C::Yellow}},
    {QStringLiteral("mjs"), {F::Mfixx, 0xF129, C::Blue}},
    {QStringLiteral("cjs"), {F::Mfixx, 0xF129, C::Green}},
    {QStringLiteral("ts"), {F::FileIcons, 0x2A6, C::Blue}},
    {QStringLiteral("tsx"), {F::FileIcons, 0xE9E7, C::Blue}},
    {QStringLiteral("jsx"), {F::FileIcons, 0xE9E6, C::Blue}},
    {QStringLiteral("json"), {F::FileIcons, 0xEABE, C::Cyan}},
    {QStringLiteral("yaml"), yaml},
    {QStringLiteral("yml"), yaml},
    {QStringLiteral("toml"), {F::FileIcons, 0x1F143, C::Green}},
    {QStringLiteral("md"), markdown},
    {QStringLiteral("markdown"), markdown},
    {QStringLiteral("txt"), {F::FontAwesome, 0xF0F6, C::Blue}},
    {QStringLiteral("sh"), shell},
    {QStringLiteral("bash"), shell},
    {QStringLiteral("zsh"), {F::FileIcons, 0xF0C8, C::Blue}},
    {QStringLiteral("py"), {F::Mfixx, 0xF14C, C::Blue}},
    {QStringLiteral("go"), {F::FileIcons, 0xEAAE, C::Blue}},
    // Atom colours Rust maroon, which this palette folds into orange.
    {QStringLiteral("rs"), {F::Devopicons, 0xE6A8, C::Orange}},
    {QStringLiteral("rb"), {F::Mfixx, 0xF150, C::Red}},
    {QStringLiteral("java"), {F::Mfixx, 0xF126, C::Purple}},
    {QStringLiteral("kt"), {F::FileIcons, 0xE989, C::Blue}},
    {QStringLiteral("c"), {F::Mfixx, 0xF106, C::Blue}},
    {QStringLiteral("h"), {F::Mfixx, 0xF106, C::Purple}},
    {QStringLiteral("cpp"), {F::Mfixx, 0xF10B, C::Blue}},
    {QStringLiteral("hpp"), {F::Mfixx, 0xF10B, C::Purple}},
    {QStringLiteral("cs"), {F::Mfixx, 0xF10C, C::Blue}},
    {QStringLiteral("php"), {F::FileIcons, 0xF147, C::Blue}},
    {QStringLiteral("html"), {F::FontAwesome, 0xF13B, C::Orange}},
    {QStringLiteral("css"), {F::FontAwesome, 0xF13C, C::Blue}},
    {QStringLiteral("scss"), {F::Devopicons, 0xE64B, C::Pink}},
    {QStringLiteral("sql"), {F::Mfixx, 0xF10E, C::Orange}},
    {QStringLiteral("xml"), {F::FontAwesome, 0xF121, C::Blue}},
    {QStringLiteral("svg"), {F::Mfixx, 0xF15C, C::Yellow}},
    {QStringLiteral("png"), {F::FontAwesome, 0xF1C5, C::Orange}},
    {QStringLiteral("jpg"), {F::FontAwesome, 0xF1C5, C::Green}},
    {QStringLiteral("jpeg"), {F::FontAwesome, 0xF1C5, C::Green}},
    {QStringLiteral("gif"), {F::FontAwesome, 0xF1C5, C::Yellow}},
    {QStringLiteral("webp"), {F::FontAwesome, 0xF1C5, C::Blue}},
    {QStringLiteral("pdf"), {F::FontAwesome, 0xF1C1, C::Red}},
    {QStringLiteral("zip"), {F::FontAwesome, 0xF1C6, C::Grey}},
    {QStringLiteral("gz"), {F::FontAwesome, 0xF1C6, C::Blue}},
    {QStringLiteral("dart"), {F::Devopicons, 0xE698, C::Cyan}},
    {QStringLiteral("lua"), {F::FileIcons, 0xE91B, C::Blue}},
    {QStringLiteral("vue"), {F::FileIcons, 0xE906, C::Green}},
    {QStringLiteral("svelte"), {F::FileIcons, 0x33DC, C::Orange}},
};
}

Icon icon(const QString &rawName, bool isDirectory)
{
    if (isDirectory)
        return folder;
    const QString name = rawName.toLower();
    if (const auto it = names.constFind(name); it != names.cend())
        return *it;
    for (const auto &[prefix, icon] : prefixes)
        if (name.startsWith(prefix))
            return icon;
    if (name.endsWith(QLatin1String(".lock")) || name.endsWith(QLatin1String("-lock.json")))
        return lock;
    qsizetype start = 0;
    while (start < name.size() && name[start] == QLatin1Char('.'))
        ++start;
    const QStringList parts = name.mid(start).split(QLatin1Char('.'));
    if (parts.size() < 2)
        return file;
    return extensions.value(parts.last(), file);
}
}
