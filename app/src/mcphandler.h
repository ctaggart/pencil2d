#ifndef MCPHANDLER_H
#define MCPHANDLER_H

#include <QObject>
#include <QMutex>
#include "ziginterop.h"

class Editor;
class MainWindow2;

/// Bridges MCP tool calls from Zig TCP thread to the Qt main thread.
/// All Editor mutations are dispatched via BlockingQueuedConnection.
class McpHandler : public QObject
{
    Q_OBJECT
public:
    explicit McpHandler(Editor* editor, MainWindow2* mainWindow, QObject* parent = nullptr);
    ~McpHandler() override;

    bool start(int port);
    void stop();

    /// C callback entry point — called from Zig thread.
    static size_t onToolCall(void* userdata, const char* method,
                             const char* params_json, char* response_buf,
                             size_t response_buf_len);

public slots:
    /// Executes on the main thread via BlockingQueuedConnection.
    QString handleToolOnMainThread(const QString& method, const QString& paramsJson);

private:
    QString handleToolsList();
    QString handleTool(const QString& name, const QString& paramsJson);

    // Tool implementations
    QString toolProjectInfo();
    QString toolLayerList();
    QString toolLayerAdd(const QString& paramsJson);
    QString toolKeyframeList(const QString& paramsJson);
    QString toolKeyframeAdd(const QString& paramsJson);
    QString toolGotoFrame(const QString& paramsJson);
    QString toolPlay();
    QString toolStop();
    QString toolUndo();
    QString toolRedo();

    Editor* mEditor;
    MainWindow2* mMainWindow;
    QMutex mMutex; // Serialize MCP requests
    bool mRunning = false;
};

#endif // MCPHANDLER_H
