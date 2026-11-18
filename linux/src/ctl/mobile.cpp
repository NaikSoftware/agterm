// elisctl mobile: a TLS relay that lets the elis Mobile app speak the control protocol over the network.
// The phone sends the same {cmd, target, args} lines elisctl sends, plus an "id" echoed on the answer; each line is
// forwarded to the app's control socket. Nothing listens unless `elisctl mobile serve` runs, by hand or as the app's
// child while Settings ▸ Connect a Phone is switched on (src/app/phone.cpp).
#include "mobile.h"

#include "paths.h"
#include "qrcodegen/qrcodegen.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHostInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QNetworkInterface>
#include <QPointer>
#include <QProcess>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSslKey>
#include <QSslServer>
#include <QSslSocket>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <cstdio>
#include <unistd.h>

namespace {
QString mobileDir()
{
    return stateDir() + QStringLiteral("/mobile");
}

// <state>/mobile holds the key and the token: refuse it unless only we can enter it
bool ensurePrivateDir(QString *error)
{
    QDir().mkpath(mobileDir());
    if (!QFile::setPermissions(mobileDir(), QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner)
        || QFileInfo(mobileDir()).ownerId() != ::getuid())
        return *error = QStringLiteral("cannot make %1 private to you").arg(mobileDir()), false;
    return true;
}

int fail(const QString &message)
{
    fprintf(stderr, "elisctl: %s\n", qPrintable(message));
    return 1;
}

bool writePrivate(const QString &path, const QByteArray &data)
{
    QFile f(path);
    // created owner-only, so the token is never readable by others even for a moment
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate, QFileDevice::ReadOwner | QFileDevice::WriteOwner)
        || !f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner))
        return false;
    return f.write(data) == data.size();
}

QString tokenPath()
{
    return mobileDir() + QStringLiteral("/token");
}

// read on every request, so `mobile reset` cuts off phones holding the old token at once
QByteArray currentToken()
{
    QFile f(tokenPath());
    const QByteArray t = f.open(QIODevice::ReadOnly) ? f.readAll().trimmed() : QByteArray();
    return t.size() >= 32 ? t : QByteArray();
}

// 32 random bytes, base64url: the pairing secret every connection must present first
QByteArray loadToken(QString *error, bool fresh = false)
{
    const QString path = tokenPath();
    if (const QByteArray t = currentToken(); !t.isEmpty() && !fresh)
        return t;
    QByteArray raw(32, Qt::Uninitialized);
    QRandomGenerator::system()->generate(raw.begin(), raw.end());
    const QByteArray token = raw.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    if (!writePrivate(path, token + '\n'))
        return *error = QStringLiteral("cannot write %1").arg(path), QByteArray();
    return token;
}

// a self-signed P-256 certificate; the phone pins its SHA-256 at pairing, so no CA is involved
bool ensureCertificate(QString *error)
{
    const QString cert = mobileDir() + QStringLiteral("/cert.pem"), key = mobileDir() + QStringLiteral("/key.pem");
    if (QFile::exists(cert) && QFile::exists(key))
        return true;
    QProcess p;
    p.start(QStringLiteral("openssl"), {"req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
                                        "-subj", "/CN=elis", "-keyout", key, "-out", cert});
    if (!p.waitForFinished(30000) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        QFile::remove(cert), QFile::remove(key);
        return *error = QStringLiteral("cannot create a certificate with openssl: %1").arg(QString::fromLocal8Bit(p.readAllStandardError()).trimmed()), false;
    }
    QFile::setPermissions(key, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return true;
}

bool sameSecret(const QByteArray &a, const QByteArray &b)
{
    unsigned char diff = a.size() != b.size();
    for (qsizetype i = 0; i < qMax(a.size(), b.size()); ++i)
        diff |= (i < a.size() ? a[i] : 0) ^ (i < b.size() ? b[i] : 0);
    return diff == 0;
}

// half-block rows with explicit black/white, so the code scans on dark and light terminal themes alike
void printQr(const QString &text)
{
    const auto qr = qrcodegen::QrCode::encodeText(text.toUtf8().constData(), qrcodegen::QrCode::Ecc::LOW);
    const int border = 2, size = qr.getSize();
    auto dark = [&](int x, int y) { return qr.getModule(x - border, y - border); }; // out of range reads light
    for (int y = 0; y < size + 2 * border; y += 2) {
        for (int x = 0; x < size + 2 * border; ++x)
            printf("\x1b[%d;%dm▀", dark(x, y) ? 30 : 97, dark(x, y + 1) ? 40 : 107);
        printf("\x1b[0m\n");
    }
}

// the first one goes in the QR code, so container and VM bridges, which a phone rarely reaches, come last
QStringList lanAddresses()
{
    QStringList out, bridges;
    for (const QNetworkInterface &i : QNetworkInterface::allInterfaces()) {
        if (!i.flags().testFlag(QNetworkInterface::IsUp))
            continue;
        const bool bridge = QRegularExpression(QStringLiteral("^(docker|br-|virbr|veth|lxc|lxd|podman|cni|vmnet|vboxnet)")).match(i.name()).hasMatch();
        for (const QNetworkAddressEntry &e : i.addressEntries())
            if (const QHostAddress a = e.ip(); a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback() && !a.isLinkLocal())
                (bridge ? bridges : out) << a.toString();
    }
    return out + bridges;
}

QString pairLink(const QString &host, quint16 port, const QByteArray &token, const QByteArray &fingerprint)
{
    QUrl url(QStringLiteral("elis://pair"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("h"), host);
    q.addQueryItem(QStringLiteral("p"), QString::number(port));
    q.addQueryItem(QStringLiteral("t"), QString::fromLatin1(token));
    q.addQueryItem(QStringLiteral("f"), QString::fromLatin1(fingerprint));
    q.addQueryItem(QStringLiteral("n"), QHostInfo::localHostName());
    url.setQuery(q);
    return url.toString(QUrl::FullyEncoded);
}

void send(QSslSocket *s, const QJsonObject &o)
{
    s->write(QJsonDocument(o).toJson(QJsonDocument::Compact) + '\n');
}

// one control request on its own connection, as elisctl does; the answer goes back tagged with the phone's id
void forward(const QString &socketPath, QPointer<QSslSocket> phone, QJsonObject request)
{
    const QJsonValue id = request.take(QStringLiteral("id"));
    auto *local = new QLocalSocket(phone);
    auto buffer = std::make_shared<QByteArray>();
    auto answer = [phone, id, local](QJsonObject r) {
        local->disconnect();
        local->deleteLater();
        if (!phone)
            return;
        r.insert(QStringLiteral("id"), id);
        send(phone, r);
    };
    QObject::connect(local, &QLocalSocket::connected, local, [local, request] { local->write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n'); });
    QObject::connect(local, &QLocalSocket::readyRead, local, [local, buffer, answer] {
        *buffer += local->readAll();
        if (buffer->contains('\n'))
            answer(QJsonDocument::fromJson(buffer->left(buffer->indexOf('\n'))).object());
    });
    QObject::connect(local, &QLocalSocket::errorOccurred, local, [local, buffer, answer](QLocalSocket::LocalSocketError e) {
        if (e == QLocalSocket::PeerClosedError && !buffer->trimmed().isEmpty())
            return answer(QJsonDocument::fromJson(buffer->trimmed()).object());
        answer({{"ok", false}, {"error", QStringLiteral("Elis is not reachable: %1").arg(local->errorString())}});
    });
    local->connectToServer(socketPath);
}

int serve(const QString &socketPath, const QHash<QString, QString> &opt)
{
    if (!QSslSocket::supportsSsl())
        return fail(QStringLiteral("Qt has no TLS backend here (install the OpenSSL plugin)"));
    QString error;
    if (!ensurePrivateDir(&error))
        return fail(error);
    const QByteArray token = loadToken(&error);
    if (token.isEmpty() || !ensureCertificate(&error))
        return fail(error);
    QFile certFile(mobileDir() + QStringLiteral("/cert.pem")), keyFile(mobileDir() + QStringLiteral("/key.pem"));
    if (!certFile.open(QIODevice::ReadOnly) || !keyFile.open(QIODevice::ReadOnly))
        return fail(QStringLiteral("cannot read the certificate in %1").arg(mobileDir()));
    const QSslCertificate cert(certFile.readAll());
    const QSslKey key(keyFile.readAll(), QSsl::Ec);
    if (cert.isNull() || key.isNull())
        return fail(QStringLiteral("the certificate in %1 is unreadable; delete cert.pem and key.pem to make a new one").arg(mobileDir()));
    const QByteArray fingerprint = cert.digest(QCryptographicHash::Sha256).toHex();

    QSslConfiguration conf = QSslConfiguration::defaultConfiguration();
    conf.setLocalCertificate(cert);
    conf.setPrivateKey(key);
    conf.setPeerVerifyMode(QSslSocket::VerifyNone);
    auto *server = new QSslServer(qApp);
    server->setSslConfiguration(conf);
    server->setHandshakeTimeout(3000);     // a peer that never speaks TLS gives its slot back fast
    server->setMaxPendingConnections(128); // Qt counts handshaking sockets against this
    bool portOk = true;
    const quint16 port = opt.value(QStringLiteral("port"), QStringLiteral("8765")).toUShort(&portOk);
    const QHostAddress bind(opt.value(QStringLiteral("bind"), QStringLiteral("0.0.0.0")));
    if (!portOk || port == 0 || bind.isNull())
        return fail(QStringLiteral("--port takes 1-65535 and --bind an IP address"));
    if (!server->listen(bind, port))
        return fail(QStringLiteral("cannot listen on %1:%2: %3").arg(bind.toString()).arg(port).arg(server->errorString()));

    QStringList hosts = opt.contains(QStringLiteral("host")) ? QStringList{opt.value(QStringLiteral("host"))} : lanAddresses();
    if (hosts.isEmpty())
        hosts << QStringLiteral("127.0.0.1");
    const QString link = pairLink(hosts.first(), port, token, fingerprint);
    if (!opt.contains(QStringLiteral("no-qr")))
        printQr(link);
    printf("\nScan the code in Elis Mobile, or paste the link:\n  %s\n", qPrintable(link));
    for (const QString &h : hosts.mid(1))
        printf("  %s\n", qPrintable(pairLink(h, port, token, fingerprint)));
    printf("\nListening on %s:%u. Anyone with the link controls your terminals; `elisctl mobile reset` revokes it. Ctrl+C stops.\n",
           qPrintable(bind.toString()), port);
    fflush(stdout);

    QObject::connect(server, &QSslServer::errorOccurred, server, [](QSslSocket *s, QAbstractSocket::SocketError) {
        fprintf(stderr, "elisctl: %s: %s\n", qPrintable(s->peerAddress().toString()), qPrintable(s->errorString()));
    });
    QObject::connect(server, &QSslServer::pendingConnectionAvailable, server, [server, socketPath] {
        while (auto *s = qobject_cast<QSslSocket *>(server->nextPendingConnection())) {
            const QString peer = s->peerAddress().toString();
            s->setSocketOption(QAbstractSocket::KeepAliveOption, 1); // a phone that vanished without a FIN is dropped
            auto *revoked = new QTimer(s); // `mobile reset` reaches idle phones too, not only at their next request
            QObject::connect(revoked, &QTimer::timeout, s, [s] {
                if (s->property("authed").toBool() && !sameSecret(s->property("token").toByteArray(), currentToken()))
                    s->abort();
            });
            revoked->start(5000);
            QObject::connect(s, &QSslSocket::disconnected, s, &QObject::deleteLater);
            QTimer::singleShot(10000, s, [s] { // an unauthenticated connection does not linger
                if (!s->property("authed").toBool())
                    s->abort();
            });
            QObject::connect(s, &QSslSocket::readyRead, s, [s, socketPath, peer] {
                while (s->canReadLine()) {
                    const QJsonObject o = QJsonDocument::fromJson(s->readLine(maxRequestBytes + 1)).object();
                    const QByteArray token = currentToken();
                    if (s->property("authed").toBool()) {
                        if (token.isEmpty() || !sameSecret(s->property("token").toByteArray(), token))
                            return s->abort(); // revoked by `mobile reset`
                        forward(socketPath, s, o);
                        continue;
                    }
                    const QByteArray offered = o.value(QStringLiteral("auth")).toString().toLatin1();
                    if (token.isEmpty() || !sameSecret(offered, token)) {
                        fprintf(stderr, "elisctl: refused %s: wrong token\n", qPrintable(peer));
                        send(s, {{"ok", false}, {"id", o.value(QStringLiteral("id"))}, {"error", QStringLiteral("unauthorized")}});
                        QObject::disconnect(s, &QSslSocket::readyRead, nullptr, nullptr); // lines already sent are not more attempts
                        s->disconnectFromHost();
                        return;
                    }
                    s->setProperty("authed", true);
                    s->setProperty("token", offered);
                    fprintf(stderr, "elisctl: phone connected from %s\n", qPrintable(peer));
                    send(s, {{"ok", true}, {"id", o.value(QStringLiteral("id"))}, {"result", QJsonObject{{"host", QHostInfo::localHostName()}, {"version", QLatin1String(appVersion)}}}});
                }
                if (s->bytesAvailable() > (s->property("authed").toBool() ? maxRequestBytes : 4096)) // the auth line is ~60 bytes
                    s->abort();
            });
        }
    });
    return QCoreApplication::exec();
}
} // namespace

int mobileCommand(const QString &sub, const QString &socketPath, const QHash<QString, QString> &opt)
{
    if (sub == QLatin1String("serve"))
        return serve(socketPath, opt);
    if (sub == QLatin1String("reset")) {
        QString error;
        if (!ensurePrivateDir(&error) || loadToken(&error, true).isEmpty())
            return fail(error);
        printf("Pairing revoked: paired phones are disconnected. Restart `elisctl mobile serve` for the new code.\n");
        return 0;
    }
    return fail(QStringLiteral("usage: elisctl mobile serve [--port N] [--bind ADDR] [--host NAME] [--no-qr] | reset"));
}
