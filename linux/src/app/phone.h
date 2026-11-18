#pragma once

#include <QImage>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QStringList>

class QWidget;

// The phone relay without a terminal: the app runs `elisctl mobile serve` as its child, one for all windows, and starts
// it again at launch while it is switched on. The switch, the port and the address the code shows live in
// <state>/mobile/desktop.json.
class PhoneRelay : public QObject
{
    Q_OBJECT
public:
    static PhoneRelay *instance();
    ~PhoneRelay() override;

    bool enabled() const { return m_on; }
    bool listening() const { return !m_links.isEmpty(); }
    quint16 port() const { return m_port; }
    QStringList hosts() const;   // one per address serve offered, the best guess first
    QString host() const;        // the address the code shows: the chosen one, else the first offered
    QString link() const;        // the pairing link for host(); empty until serve is listening
    QString error() const { return m_error; }
    QString lastEvent() const { return m_event; }

    void setEnabled(bool on);
    void setPort(quint16 port);
    void setHost(const QString &host);
    bool revoke(QString *error); // a new token: paired phones are cut off and the code changes

Q_SIGNALS:
    void changed();

private:
    PhoneRelay();
    void start();
    void stop();
    void save() const;

    QPointer<QProcess> m_proc;
    bool m_on = false;
    quint16 m_port = 8765;
    QString m_host;
    QStringList m_links;
    QString m_error, m_event;
};

QString pairLinkWithHost(const QString &link, const QString &host);
QImage qrImage(const QString &text); // one pixel per module, black on white, four modules of quiet zone
void showPhoneDialog(QWidget *parent);
