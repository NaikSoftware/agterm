// Connect a Phone: the agterm Mobile relay switched on from the GUI. The relay itself stays in agtermctl (src/ctl/mobile.cpp);
// this runs it as a child and shows its pairing link as a QR code.
#include "phone.h"

#include "../ctl/qrcodegen/qrcodegen.hpp"
#include "paths.h"

#include <QApplication>
#include <QCheckBox>
#include <QClipboard>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFile>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
#include <QPushButton>
#include <QSaveFile>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QUrl>
#include <QUrlQuery>
#include <QVBoxLayout>

#include <csignal>
#include <sys/prctl.h>

namespace {
QString mobileDir()
{
    return stateDir() + QStringLiteral("/mobile");
}

QString agtermctl()
{
    return QCoreApplication::applicationDirPath() + QStringLiteral("/agtermctl");
}

QString hostOf(const QString &link)
{
    return QUrlQuery(QUrl(link)).queryItemValue(QStringLiteral("h"));
}
} // namespace

QString pairLinkWithHost(const QString &link, const QString &host)
{
    QUrl url(link);
    QUrlQuery q(url);
    if (host.trimmed().isEmpty() || !q.hasQueryItem(QStringLiteral("h")))
        return link;
    q.removeQueryItem(QStringLiteral("h"));
    QList<std::pair<QString, QString>> items = q.queryItems(QUrl::FullyDecoded);
    items.prepend({QStringLiteral("h"), host.trimmed()});
    q.setQueryItems(items);
    url.setQuery(q);
    return url.toString(QUrl::FullyEncoded);
}

QImage qrImage(const QString &text)
{
    const auto qr = qrcodegen::QrCode::encodeText(text.toUtf8().constData(), qrcodegen::QrCode::Ecc::LOW);
    const int border = 4, size = qr.getSize() + 2 * border;
    QImage img(size, size, QImage::Format_RGB32);
    img.fill(Qt::white); // black on white whatever the theme: scanners expect a light quiet zone
    for (int y = 0; y < qr.getSize(); ++y)
        for (int x = 0; x < qr.getSize(); ++x)
            if (qr.getModule(x, y))
                img.setPixel(x + border, y + border, qRgb(0, 0, 0));
    return img;
}

PhoneRelay *PhoneRelay::instance()
{
    static PhoneRelay *relay = new PhoneRelay;
    return relay;
}

PhoneRelay::PhoneRelay()
    : QObject(qApp)
{
    QFile f(mobileDir() + QStringLiteral("/desktop.json"));
    if (f.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        m_on = o.value(QStringLiteral("on")).toBool();
        m_port = quint16(qBound(1, o.value(QStringLiteral("port")).toInt(8765), 65535));
        m_host = o.value(QStringLiteral("host")).toString();
    }
    connect(qApp, &QCoreApplication::aboutToQuit, this, &PhoneRelay::stop);
    if (m_on)
        start();
}

PhoneRelay::~PhoneRelay()
{
    stop();
}

void PhoneRelay::save() const
{
    QDir().mkpath(mobileDir());
    QFile::setPermissions(mobileDir(), QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner); // holds the token too
    QSaveFile f(mobileDir() + QStringLiteral("/desktop.json"));
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(QJsonObject{{"on", m_on}, {"port", m_port}, {"host", m_host}}).toJson());
        f.commit();
    }
}

void PhoneRelay::start()
{
    stop();
    m_links.clear();
    m_error.clear();
    m_event.clear();
    auto *p = new QProcess(this);
    m_proc = p;
    p->setChildProcessModifier([] { ::prctl(PR_SET_PDEATHSIG, SIGTERM); }); // a crashed app must not leave the port bound
    auto lastError = std::make_shared<QString>();
    // whole lines from one of the child's pipes; a line that never ends is noise, not something to keep
    auto lines = [](QByteArray &buffer, const QByteArray &more) {
        buffer += more;
        QStringList out;
        for (qsizetype i; (i = buffer.indexOf('\n')) >= 0; buffer.remove(0, i + 1))
            out << QString::fromUtf8(buffer.left(i)).trimmed();
        if (buffer.size() > 4096)
            buffer.clear();
        return out;
    };
    auto outBuffer = std::make_shared<QByteArray>(), errBuffer = std::make_shared<QByteArray>();
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p, lines, outBuffer] {
        bool more = false;
        for (const QString &line : lines(*outBuffer, p->readAllStandardOutput()))
            if (line.startsWith(QLatin1String("agterm://")))
                m_links << line, more = true;
        if (more)
            Q_EMIT changed();
    });
    connect(p, &QProcess::readyReadStandardError, this, [this, p, lines, errBuffer, lastError] {
        for (QString line : lines(*errBuffer, p->readAllStandardError())) {
            if (line.startsWith(QLatin1String("agtermctl: ")))
                line.remove(0, 11);
            *lastError = line;
            if (line.startsWith(QLatin1String("phone connected")) || line.startsWith(QLatin1String("refused")))
                m_event = line, Q_EMIT changed();
        }
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart)
            m_error = tr("Cannot run %1: %2").arg(agtermctl(), p->errorString()), Q_EMIT changed();
    });
    connect(p, &QProcess::finished, this, [this, p, lastError] {
        if (m_error.isEmpty())
            m_error = lastError->isEmpty() ? tr("The relay stopped.") : *lastError;
        m_links.clear();
        p->deleteLater();
        Q_EMIT changed();
    });
    p->start(agtermctl(), {QStringLiteral("mobile"), QStringLiteral("serve"), QStringLiteral("--no-qr"), QStringLiteral("--socket"), socketPath(),
                           QStringLiteral("--port"), QString::number(m_port)});
    Q_EMIT changed();
}

void PhoneRelay::stop()
{
    if (!m_proc)
        return;
    m_proc->disconnect(this);
    m_proc->kill();
    m_proc->waitForFinished(2000); // the port is free before a restart binds it again
    delete m_proc;
    m_links.clear();
}

QStringList PhoneRelay::hosts() const
{
    QStringList out;
    for (const QString &l : m_links)
        out << hostOf(l);
    return out;
}

QString PhoneRelay::host() const
{
    return m_host.isEmpty() ? hosts().value(0) : m_host;
}

QString PhoneRelay::link() const
{
    return m_links.isEmpty() ? QString() : pairLinkWithHost(m_links.first(), host());
}

void PhoneRelay::setEnabled(bool on)
{
    m_on = on;
    save();
    if (on)
        start();
    else
        stop(), m_error.clear(), m_event.clear(), Q_EMIT changed();
}

void PhoneRelay::setPort(quint16 port)
{
    if (port == m_port || port == 0)
        return;
    m_port = port;
    save();
    if (m_on)
        start();
}

void PhoneRelay::setHost(const QString &host)
{
    const QString h = host.trimmed() == hosts().value(0) ? QString() : host.trimmed(); // the default follows the network
    if (h == m_host)
        return;
    m_host = h;
    save();
    Q_EMIT changed();
}

bool PhoneRelay::revoke(QString *error)
{
    QProcess p;
    p.start(agtermctl(), {QStringLiteral("mobile"), QStringLiteral("reset")});
    if (!p.waitForFinished(10000) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        *error = QString::fromLocal8Bit(p.readAllStandardError()).trimmed();
        if (error->isEmpty())
            *error = p.errorString();
        return false;
    }
    if (m_on)
        start(); // serve prints the token it started with; a new run shows the new one
    return true;
}

void showPhoneDialog(QWidget *parent)
{
    if (auto *open = parent->findChild<QDialog *>(QStringLiteral("phoneDialog"))) {
        open->raise();
        open->activateWindow();
        return;
    }
    PhoneRelay *relay = PhoneRelay::instance();
    auto *dlg = new QDialog(parent);
    dlg->setObjectName(QStringLiteral("phoneDialog"));
    dlg->setAttribute(Qt::WA_DeleteOnClose);
    dlg->setWindowTitle(QObject::tr("Connect a Phone"));

    auto *on = new QCheckBox(QObject::tr("Let agterm Mobile connect to this computer"));
    on->setObjectName(QStringLiteral("phoneOn"));
    auto *code = new QLabel;
    code->setObjectName(QStringLiteral("phoneCode"));
    code->setAlignment(Qt::AlignCenter);
    code->setMinimumSize(300, 300);
    code->setWordWrap(true);
    auto *hosts = new QComboBox;
    hosts->setEditable(true);
    hosts->setMinimumContentsLength(24); // a full IPv4 address or a Tailscale name
    hosts->setToolTip(QObject::tr("The address the phone reaches this computer at; type a name for a VPN such as Tailscale"));
    auto *port = new QSpinBox;
    port->setRange(1024, 65535);
    port->setValue(relay->port());
    auto *link = new QLineEdit;
    link->setObjectName(QStringLiteral("phoneLink"));
    link->setReadOnly(true);
    auto *copy = new QPushButton(QIcon::fromTheme(QStringLiteral("edit-copy")), QObject::tr("Copy"));
    auto *status = new QLabel;
    status->setObjectName(QStringLiteral("phoneStatus"));
    status->setWordWrap(true);
    auto *warning = new QLabel(QObject::tr("Anyone with this code controls your terminals until you revoke it. "
                                           "Scan it in agterm Mobile, or send the link to the phone and paste it there."));
    warning->setWordWrap(true);
    auto *revoke = new QPushButton(QIcon::fromTheme(QStringLiteral("edit-delete")), QObject::tr("Revoke Paired Phones…"));

    auto *linkRow = new QHBoxLayout;
    linkRow->addWidget(link, 1);
    linkRow->addWidget(copy);
    auto *form = new QFormLayout;
    form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow); // Breeze keeps a combo at its hint, too narrow for an address
    form->addRow(QObject::tr("Address:"), hosts);
    form->addRow(QObject::tr("Port:"), port);
    form->addRow(QObject::tr("Link:"), linkRow);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close);
    buttons->addButton(revoke, QDialogButtonBox::ResetRole);
    auto *layout = new QVBoxLayout(dlg);
    layout->addWidget(on);
    layout->addWidget(code, 1);
    layout->addLayout(form);
    layout->addWidget(status);
    layout->addWidget(warning);
    layout->addWidget(buttons);

    auto refresh = [=] {
        const QSignalBlocker b1(on), b2(hosts), b3(port);
        on->setChecked(relay->enabled());
        QStringList items;
        for (int i = 0; i < hosts->count(); ++i)
            items << hosts->itemText(i);
        if (items != relay->hosts()) {
            hosts->clear();
            hosts->addItems(relay->hosts());
        }
        if (hosts->currentText() != relay->host())
            hosts->setEditText(relay->host());
        port->setValue(relay->port());
        const QString l = relay->link();
        link->setText(l);
        link->setCursorPosition(0); // the host and port lead the link
        if (!l.isEmpty()) {
            const QImage img = qrImage(l);
            const int scale = qMax(2, 300 / img.width());
            code->setPixmap(QPixmap::fromImage(img.scaled(img.size() * scale, Qt::IgnoreAspectRatio, Qt::FastTransformation)));
        } else {
            code->setPixmap({});
            code->setText(!relay->enabled() ? QObject::tr("Phone access is off.") : relay->error().isEmpty() ? QObject::tr("Starting…") : QString());
        }
        for (QWidget *w : std::initializer_list<QWidget *>{hosts, link, copy})
            w->setEnabled(!l.isEmpty());
        if (!relay->error().isEmpty())
            status->setText(QObject::tr("<b>Not listening:</b> %1").arg(relay->error().toHtmlEscaped()));
        else if (!l.isEmpty())
            status->setText(QObject::tr("Listening on port %1.").arg(relay->port())
                            + (relay->lastEvent().isEmpty() ? QString() : QStringLiteral(" ") + relay->lastEvent().toHtmlEscaped() + QLatin1Char('.')));
        else
            status->clear();
    };
    QObject::connect(relay, &PhoneRelay::changed, dlg, refresh);
    QObject::connect(on, &QCheckBox::toggled, relay, &PhoneRelay::setEnabled);
    QObject::connect(hosts, &QComboBox::currentTextChanged, relay, &PhoneRelay::setHost);
    QObject::connect(port, &QSpinBox::editingFinished, relay, [relay, port] { relay->setPort(quint16(port->value())); });
    QObject::connect(copy, &QPushButton::clicked, dlg, [link] { QGuiApplication::clipboard()->setText(link->text()); });
    QObject::connect(buttons, &QDialogButtonBox::rejected, dlg, &QDialog::close);
    QObject::connect(revoke, &QPushButton::clicked, dlg, [dlg, relay] {
        if (QMessageBox::question(dlg, QObject::tr("Revoke Paired Phones"),
                                  QObject::tr("Every paired phone is disconnected and must scan the new code. Revoke?"))
            != QMessageBox::Yes)
            return;
        if (QString error; !relay->revoke(&error))
            QMessageBox::warning(dlg, QObject::tr("Revoke Paired Phones"), error);
    });
    refresh();
    dlg->show();
}
