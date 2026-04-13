#ifndef MCPHANDLER_H
#define MCPHANDLER_H

#include <QObject>
#include <QMutex>
#include "ziginterop.h"

class Editor;
class MainWindow2;

/// Thin bridge: starts Zig MCP server, provides Qt bridge functions.
/// All MCP tool dispatch logic lives in Zig (mcp_embedded.zig).
class McpHandler : public QObject
{
    Q_OBJECT
public:
    explicit McpHandler(Editor* editor, MainWindow2* mainWindow, QObject* parent = nullptr);
    ~McpHandler() override;

    bool start(int port);
    void stop();

    static size_t onToolCall(void* userdata, const char* method,
                             const char* params_json, char* response_buf,
                             size_t response_buf_len);

public slots:
    QString handleToolOnMainThread(const QString& method, const QString& paramsJson);

private:
    Editor* mEditor;
    MainWindow2* mMainWindow;
    QMutex mMutex;
    bool mRunning = false;
};

#endif // MCPHANDLER_H
