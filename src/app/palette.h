#pragma once

#include <QFrame>
#include <functional>

class QLineEdit;
class QListWidget;

// agterm's fuzzy palettes: type to filter, arrows or Ctrl-J/Ctrl-K to move, Enter to run, Esc to dismiss.
// In switcher mode (Ctrl-Tab) there is no search field: Tab walks the list and releasing Ctrl runs the pick.
class Palette : public QFrame
{
    Q_OBJECT
public:
    struct Item {
        QString title, subtitle;
        std::function<void()> run;
        bool enabled = true; // a disabled action still shows and matches, greyed out, and does nothing
    };

    explicit Palette(QWidget *window);
    void open(const QString &placeholder, const QList<Item> &items, bool switcher = false);
    void step(int delta);
    bool switching() const { return isVisible() && m_switcher; }

    static bool fuzzyMatch(const QString &needle, const QString &haystack); // case-insensitive subsequence

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void filter();
    void runCurrent();
    void place();

    QLineEdit *m_search;
    QListWidget *m_list;
    QList<Item> m_items;
    bool m_switcher = false;
};
