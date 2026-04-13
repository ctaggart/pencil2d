#include "mcphandler.h"
#include "editor.h"
#include "layermanager.h"
#include "playbackmanager.h"
#include "undoredomanager.h"
#include "object.h"
#include "layer.h"
#include "layerbitmap.h"
#include "layervector.h"
#include "layercamera.h"
#include "layersound.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QThread>
#include <QDebug>

McpHandler::McpHandler(Editor* editor, MainWindow2* mainWindow, QObject* parent)
    : QObject(parent), mEditor(editor), mMainWindow(mainWindow)
{
}

McpHandler::~McpHandler()
{
    stop();
}

bool McpHandler::start(int port)
{
    if (mRunning) return false;
    int result = zig_mcp_start(static_cast<uint16_t>(port), &McpHandler::onToolCall, this);
    if (result == 0) {
        mRunning = true;
        qDebug() << "MCP server started on port" << port;
    }
    return result == 0;
}

void McpHandler::stop()
{
    if (!mRunning) return;
    zig_mcp_stop();
    mRunning = false;
    qDebug() << "MCP server stopped";
}

// Static C callback — runs on Zig thread
size_t McpHandler::onToolCall(void* userdata, const char* method,
                               const char* params_json, char* response_buf,
                               size_t response_buf_len)
{
    auto* self = static_cast<McpHandler*>(userdata);
    QString qMethod = QString::fromUtf8(method);
    QString qParams = QString::fromUtf8(params_json);
    QString result;

    // Serialize all MCP requests through mutex
    QMutexLocker lock(&self->mMutex);

    // Dispatch to main thread and wait for result
    if (QThread::currentThread() == self->thread()) {
        // Already on main thread (shouldn't happen, but safe)
        result = self->handleToolOnMainThread(qMethod, qParams);
    } else {
        QMetaObject::invokeMethod(self, "handleToolOnMainThread",
                                  Qt::BlockingQueuedConnection,
                                  Q_RETURN_ARG(QString, result),
                                  Q_ARG(QString, qMethod),
                                  Q_ARG(QString, qParams));
    }

    QByteArray utf8 = result.toUtf8();
    size_t len = static_cast<size_t>(utf8.size());
    if (len > response_buf_len) len = response_buf_len;
    memcpy(response_buf, utf8.constData(), len);
    return len;
}

// Runs on main thread
QString McpHandler::handleToolOnMainThread(const QString& method, const QString& paramsJson)
{
    if (method == "tools/list") return handleToolsList();
    return handleTool(method, paramsJson);
}

QString McpHandler::handleToolsList()
{
    return QString::fromUtf8(
        "{\"tools\":["
        "{\"name\":\"project_info\",\"description\":\"Get project info: layers, frames, FPS\"},"
        "{\"name\":\"layer_list\",\"description\":\"List all layers with type and keyframe count\"},"
        "{\"name\":\"layer_add\",\"description\":\"Add a layer\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"type\":{\"type\":\"string\",\"enum\":[\"bitmap\",\"vector\",\"camera\",\"sound\"]}},\"required\":[\"name\",\"type\"]}},"
        "{\"name\":\"keyframe_list\",\"description\":\"List keyframes on a layer\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"}},\"required\":[\"layer\"]}},"
        "{\"name\":\"keyframe_add\",\"description\":\"Add keyframe at position\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"integer\"},\"frame\":{\"type\":\"integer\"}},\"required\":[\"layer\",\"frame\"]}},"
        "{\"name\":\"goto_frame\",\"description\":\"Scrub to a frame (live canvas update)\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"frame\":{\"type\":\"integer\"}},\"required\":[\"frame\"]}},"
        "{\"name\":\"play\",\"description\":\"Start playback\"},"
        "{\"name\":\"stop\",\"description\":\"Stop playback\"},"
        "{\"name\":\"undo\",\"description\":\"Undo last action\"},"
        "{\"name\":\"redo\",\"description\":\"Redo last undone action\"}"
        "]}"
    );
}

static int findLayerIndex(Editor* editor, const QJsonObject& params)
{
    if (params.contains("layer")) {
        QJsonValue v = params["layer"];
        if (v.isDouble()) return v.toInt();
        if (v.isString()) {
            QString name = v.toString();
            // Try parse as number
            bool ok;
            int idx = name.toInt(&ok);
            if (ok) return idx;
            // Search by name
            Object* obj = editor->object();
            for (int i = 0; i < obj->getLayerCount(); i++) {
                if (obj->getLayer(i)->name() == name) return i;
            }
        }
    }
    return -1;
}

QString McpHandler::handleTool(const QString& name, const QString& paramsJson)
{
    if (name == "project_info") return toolProjectInfo();
    if (name == "layer_list") return toolLayerList();
    if (name == "layer_add") return toolLayerAdd(paramsJson);
    if (name == "keyframe_list") return toolKeyframeList(paramsJson);
    if (name == "keyframe_add") return toolKeyframeAdd(paramsJson);
    if (name == "goto_frame") return toolGotoFrame(paramsJson);
    if (name == "play") return toolPlay();
    if (name == "stop") return toolStop();
    if (name == "undo") return toolUndo();
    if (name == "redo") return toolRedo();
    return QStringLiteral(R"({"error":"unknown tool"})");
}

QString McpHandler::toolProjectInfo()
{
    Object* obj = mEditor->object();
    if (!obj) return R"({"error":"no project"})";

    int totalKf = 0;
    for (int i = 0; i < obj->getLayerCount(); i++)
        totalKf += obj->getLayer(i)->keyFrameCount();

    return QString(R"({"layers":%1,"keyframes":%2,"fps":%3,"current_frame":%4})")
        .arg(obj->getLayerCount())
        .arg(totalKf)
        .arg(mEditor->fps())
        .arg(mEditor->currentFrame());
}

QString McpHandler::toolLayerList()
{
    Object* obj = mEditor->object();
    if (!obj) return "[]";

    QJsonArray arr;
    for (int i = 0; i < obj->getLayerCount(); i++) {
        Layer* layer = obj->getLayer(i);
        QJsonObject lo;
        lo["index"] = i;
        lo["id"] = layer->id();
        lo["name"] = layer->name();
        lo["visible"] = layer->visible();
        lo["keyframes"] = layer->keyFrameCount();

        QString typeStr;
        switch (layer->type()) {
            case Layer::BITMAP: typeStr = "bitmap"; break;
            case Layer::VECTOR: typeStr = "vector"; break;
            case Layer::CAMERA: typeStr = "camera"; break;
            case Layer::SOUND: typeStr = "sound"; break;
            default: typeStr = "unknown"; break;
        }
        lo["type"] = typeStr;
        arr.append(lo);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QString McpHandler::toolLayerAdd(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    QString name = params["name"].toString("New Layer");
    QString type = params["type"].toString("bitmap");

    Layer* layer = nullptr;
    if (type == "bitmap") layer = mEditor->layers()->createBitmapLayer(name);
    else if (type == "vector") layer = mEditor->layers()->createVectorLayer(name);
    else if (type == "camera") layer = mEditor->layers()->createCameraLayer(name);
    else if (type == "sound") layer = mEditor->layers()->createSoundLayer(name);

    if (!layer) return R"({"error":"failed to create layer"})";

    emit mEditor->updateTimeLine();
    return QString(R"({"added":true,"id":%1})").arg(layer->id());
}

QString McpHandler::toolKeyframeList(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int idx = findLayerIndex(mEditor, params);
    if (idx < 0) return R"({"error":"layer not found"})";

    Layer* layer = mEditor->object()->getLayer(idx);
    QJsonArray arr;
    layer->foreachKeyFrame([&](KeyFrame* kf) {
        QJsonObject ko;
        ko["frame"] = kf->pos();
        ko["length"] = kf->length();
        arr.append(ko);
    });
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QString McpHandler::toolKeyframeAdd(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    int frame = params["frame"].toInt(1);

    if (layerIdx < 0) return R"({"error":"layer not found"})";

    KeyFrame* kf = mEditor->addKeyFrame(layerIdx, frame);
    if (!kf) return R"({"error":"could not add keyframe"})";

    emit mEditor->updateTimeLine();
    mEditor->updateFrame();
    return QString(R"({"added":true,"frame":%1})").arg(kf->pos());
}

QString McpHandler::toolGotoFrame(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int frame = params["frame"].toInt(1);
    mEditor->scrubTo(frame);
    return QString(R"({"frame":%1})").arg(mEditor->currentFrame());
}

QString McpHandler::toolPlay()
{
    mEditor->playback()->play();
    return R"({"playing":true})";
}

QString McpHandler::toolStop()
{
    mEditor->playback()->stop();
    return QString(R"({"playing":false,"frame":%1})").arg(mEditor->currentFrame());
}

QString McpHandler::toolUndo()
{
    // TODO: UndoRedoManager's undo/redo are private; needs public API
    return R"({"error":"undo not yet available via MCP"})";
}

QString McpHandler::toolRedo()
{
    return R"({"error":"redo not yet available via MCP"})";
}
