// Static Qt plugin imports for Windows — compiled only when -Dqt-static=true.

#include <QtPlugin>

// Platform integration
Q_IMPORT_PLUGIN(QWindowsIntegrationPlugin)

// Image formats
Q_IMPORT_PLUGIN(QSvgPlugin)
Q_IMPORT_PLUGIN(QGifPlugin)
Q_IMPORT_PLUGIN(QICOPlugin)
Q_IMPORT_PLUGIN(QJpegPlugin)
Q_IMPORT_PLUGIN(QTiffPlugin)
Q_IMPORT_PLUGIN(QWebpPlugin)

// Icon engine
Q_IMPORT_PLUGIN(QSvgIconPlugin)

// TLS backend for HTTPS
Q_IMPORT_PLUGIN(QSchannelBackend)
