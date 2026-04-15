// Static Qt plugin imports — compiled only when -Dqt-static=true.
// Each Q_IMPORT_PLUGIN registers a static plugin so Qt finds it at runtime.

#include <QtPlugin>

// Platform integration
Q_IMPORT_PLUGIN(QCocoaIntegrationPlugin)

// Style
Q_IMPORT_PLUGIN(QMacStylePlugin)

// Image formats
Q_IMPORT_PLUGIN(QSvgPlugin)
Q_IMPORT_PLUGIN(QGifPlugin)
Q_IMPORT_PLUGIN(QICOPlugin)
Q_IMPORT_PLUGIN(QJpegPlugin)
Q_IMPORT_PLUGIN(QICNSPlugin)
Q_IMPORT_PLUGIN(QMacHeifPlugin)
Q_IMPORT_PLUGIN(QMacJp2Plugin)
Q_IMPORT_PLUGIN(QTiffPlugin)
Q_IMPORT_PLUGIN(QWebpPlugin)

// Icon engine
Q_IMPORT_PLUGIN(QSvgIconPlugin)

// Multimedia backend
Q_IMPORT_PLUGIN(QDarwinMediaPlugin)

// TLS backend for HTTPS
Q_IMPORT_PLUGIN(QSecureTransportBackend)
