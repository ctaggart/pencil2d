#include "mcphandler.h"
#include "editor.h"
#include "layermanager.h"
#include "playbackmanager.h"
#include "undoredomanager.h"
#include "colormanager.h"
#include "toolmanager.h"
#include "object.h"
#include "layer.h"
#include "layerbitmap.h"
#include "layervector.h"
#include "layercamera.h"
#include "layersound.h"
#include "bitmapimage.h"
#include "pencildef.h"

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

    qDebug() << "MCP tool:" << qMethod << "params:" << qParams;

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
        "{\"name\":\"redo\",\"description\":\"Redo last undone action\"},"
        "{\"name\":\"draw_rect\",\"description\":\"Draw filled rectangle on current bitmap frame\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"},\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"},\"w\":{\"type\":\"integer\"},\"h\":{\"type\":\"integer\"},\"r\":{\"type\":\"integer\"},\"g\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"},\"a\":{\"type\":\"integer\"}},\"required\":[\"layer\",\"x\",\"y\",\"w\",\"h\"]}},"
        "{\"name\":\"draw_circle\",\"description\":\"Draw filled circle on current bitmap frame\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"},\"cx\":{\"type\":\"integer\"},\"cy\":{\"type\":\"integer\"},\"radius\":{\"type\":\"integer\"},\"r\":{\"type\":\"integer\"},\"g\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"},\"a\":{\"type\":\"integer\"}},\"required\":[\"layer\",\"cx\",\"cy\",\"radius\"]}},"
        "{\"name\":\"clear_frame\",\"description\":\"Clear the current bitmap frame\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"}},\"required\":[\"layer\"]}}"
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
    if (name == "layer_remove") return toolLayerRemove(paramsJson);
    if (name == "layer_rename") return toolLayerRename(paramsJson);
    if (name == "layer_visibility") return toolLayerVisibility(paramsJson);
    if (name == "keyframe_list") return toolKeyframeList(paramsJson);
    if (name == "keyframe_add") return toolKeyframeAdd(paramsJson);
    if (name == "keyframe_remove") return toolKeyframeRemove(paramsJson);
    if (name == "goto_frame") return toolGotoFrame(paramsJson);
    if (name == "play") return toolPlay();
    if (name == "stop") return toolStop();
    if (name == "undo") return toolUndo();
    if (name == "redo") return toolRedo();
    if (name == "draw_rect") return toolDrawRect(paramsJson);
    if (name == "draw_circle") return toolDrawCircle(paramsJson);
    if (name == "draw_line") return toolDrawLine(paramsJson);
    if (name == "clear_frame") return toolClearFrame(paramsJson);
    if (name == "set_color") return toolSetColor(paramsJson);
    if (name == "set_tool") return toolSetTool(paramsJson);
    if (name == "export_frame") return toolExportFrame(paramsJson);
    if (name == "set_fps") return toolSetFps(paramsJson);
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

static BitmapImage* getBitmapAtCurrentFrame(Editor* editor, int layerIdx)
{
    Layer* layer = editor->object()->getLayer(layerIdx);
    if (!layer || layer->type() != Layer::BITMAP) return nullptr;
    auto* bitmapLayer = static_cast<LayerBitmap*>(layer);
    int frame = editor->currentFrame();
    return bitmapLayer->getBitmapImageAtFrame(frame);
}

QString McpHandler::toolDrawRect(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) return R"({"error":"layer not found"})";

    BitmapImage* img = getBitmapAtCurrentFrame(mEditor, layerIdx);
    if (!img) return R"({"error":"no bitmap frame at current position"})";

    int x = params["x"].toInt(0);
    int y = params["y"].toInt(0);
    int w = params["w"].toInt(50);
    int h = params["h"].toInt(50);
    int r = params["r"].toInt(0);
    int g = params["g"].toInt(0);
    int b = params["b"].toInt(0);
    int a = params["a"].toInt(255);

    QColor color(r, g, b, a);
    QPen pen(Qt::NoPen);
    QBrush brush(color);
    img->drawRect(QRectF(x, y, w, h), pen, brush, QPainter::CompositionMode_SourceOver, false);

    mEditor->setModified(layerIdx, mEditor->currentFrame());
    mEditor->updateFrame();

    return QString(R"({"drawn":"rect","frame":%1,"layer":%2})").arg(mEditor->currentFrame()).arg(layerIdx);
}

QString McpHandler::toolDrawCircle(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) return R"({"error":"layer not found"})";

    BitmapImage* img = getBitmapAtCurrentFrame(mEditor, layerIdx);
    if (!img) return R"({"error":"no bitmap frame at current position"})";

    int cx = params["cx"].toInt(0);
    int cy = params["cy"].toInt(0);
    int radius = params["radius"].toInt(25);
    int r = params["r"].toInt(0);
    int g = params["g"].toInt(0);
    int b = params["b"].toInt(0);
    int a = params["a"].toInt(255);

    QColor color(r, g, b, a);
    QPen pen(Qt::NoPen);
    QBrush brush(color);
    img->drawEllipse(QRectF(cx - radius, cy - radius, radius * 2, radius * 2), pen, brush, QPainter::CompositionMode_SourceOver, false);

    mEditor->setModified(layerIdx, mEditor->currentFrame());
    mEditor->updateFrame();

    return QString(R"({"drawn":"circle","frame":%1,"layer":%2})").arg(mEditor->currentFrame()).arg(layerIdx);
}

QString McpHandler::toolClearFrame(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) return R"({"error":"layer not found"})";

    BitmapImage* img = getBitmapAtCurrentFrame(mEditor, layerIdx);
    if (!img) return R"({"error":"no bitmap frame at current position"})";

    img->clear();
    mEditor->setModified(layerIdx, mEditor->currentFrame());
    mEditor->updateFrame();

    return QString(R"({"cleared":true,"frame":%1,"layer":%2})").arg(mEditor->currentFrame()).arg(layerIdx);
}

QString McpHandler::toolLayerRemove(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int idx = findLayerIndex(mEditor, params);
    if (idx < 0) return R"({"error":"layer not found"})";
    if (mEditor->object()->getLayerCount() <= 1) return R"({"error":"cannot delete last layer"})";

    mEditor->object()->deleteLayer(idx);
    emit mEditor->updateTimeLine();
    emit mEditor->updateLayerCount();
    return QString(R"({"removed":true,"remaining":%1})").arg(mEditor->object()->getLayerCount());
}

QString McpHandler::toolLayerRename(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int idx = findLayerIndex(mEditor, params);
    if (idx < 0) return R"({"error":"layer not found"})";
    QString newName = params["name"].toString("Layer");

    Layer* layer = mEditor->object()->getLayer(idx);
    layer->setName(newName);
    emit mEditor->updateTimeLine();
    return QString(R"({"renamed":true,"name":"%1"})").arg(newName);
}

QString McpHandler::toolLayerVisibility(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int idx = findLayerIndex(mEditor, params);
    if (idx < 0) return R"({"error":"layer not found"})";

    Layer* layer = mEditor->object()->getLayer(idx);
    if (params.contains("visible")) {
        layer->setVisible(params["visible"].toBool());
    } else {
        layer->switchVisibility();
    }
    mEditor->updateFrame();
    return QString(R"({"visible":%1})").arg(layer->visible() ? "true" : "false");
}

QString McpHandler::toolKeyframeRemove(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) return R"({"error":"layer not found"})";
    int frame = params["frame"].toInt(mEditor->currentFrame());

    Layer* layer = mEditor->object()->getLayer(layerIdx);
    if (!layer->keyExists(frame)) return R"({"error":"no keyframe at that position"})";

    layer->removeKeyFrame(frame);
    emit mEditor->updateTimeLine();
    mEditor->updateFrame();
    return QString(R"({"removed":true,"frame":%1})").arg(frame);
}

QString McpHandler::toolDrawLine(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) return R"({"error":"layer not found"})";

    BitmapImage* img = getBitmapAtCurrentFrame(mEditor, layerIdx);
    if (!img) return R"({"error":"no bitmap frame at current position"})";

    int r = params["r"].toInt(0), g = params["g"].toInt(0), b = params["b"].toInt(0), a = params["a"].toInt(255);
    qreal w = params["width"].toDouble(2.0);
    QPointF p1(params["x0"].toDouble(), params["y0"].toDouble());
    QPointF p2(params["x1"].toDouble(), params["y1"].toDouble());

    QPen pen(QColor(r, g, b, a), w, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
    img->drawLine(p1, p2, pen, QPainter::CompositionMode_SourceOver, false);

    mEditor->setModified(layerIdx, mEditor->currentFrame());
    mEditor->updateFrame();
    return QString(R"({"drawn":"line","frame":%1})").arg(mEditor->currentFrame());
}

QString McpHandler::toolSetColor(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int r = params["r"].toInt(0), g = params["g"].toInt(0), b = params["b"].toInt(0), a = params["a"].toInt(255);
    QColor c(r, g, b, a);
    mEditor->color()->setFrontColor(c);
    return QString(R"({"color":{"r":%1,"g":%2,"b":%3,"a":%4}})").arg(r).arg(g).arg(b).arg(a);
}

QString McpHandler::toolSetTool(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    QString toolName = params["tool"].toString("pencil");

    ToolType type = PENCIL;
    if (toolName == "pencil") type = PENCIL;
    else if (toolName == "brush") type = BRUSH;
    else if (toolName == "eraser") type = ERASER;
    else if (toolName == "pen") type = PEN;
    else if (toolName == "bucket") type = BUCKET;
    else if (toolName == "eyedropper") type = EYEDROPPER;
    else if (toolName == "select") type = SELECT;
    else if (toolName == "move") type = MOVE;
    else if (toolName == "hand") type = HAND;
    else if (toolName == "polyline") type = POLYLINE;
    else if (toolName == "smudge") type = SMUDGE;
    else return R"({"error":"unknown tool type"})";

    mEditor->tools()->setCurrentTool(type);
    return QString(R"({"tool":"%1"})").arg(toolName);
}

QString McpHandler::toolExportFrame(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    QString path = params["path"].toString();
    if (path.isEmpty()) return R"({"error":"missing path"})";
    int layerIdx = findLayerIndex(mEditor, params);
    if (layerIdx < 0) layerIdx = mEditor->currentLayerIndex();

    BitmapImage* img = getBitmapAtCurrentFrame(mEditor, layerIdx);
    if (!img) return R"({"error":"no bitmap frame"})";

    Status st = img->writeFile(path);
    if (!st.ok()) return R"({"error":"write failed"})";

    return QString(R"({"exported":true,"path":"%1","frame":%2})").arg(path).arg(mEditor->currentFrame());
}

QString McpHandler::toolSetFps(const QString& paramsJson)
{
    QJsonObject params = QJsonDocument::fromJson(paramsJson.toUtf8()).object();
    int newFps = params["fps"].toInt(24);
    mEditor->setFps(newFps);
    return QString(R"({"fps":%1})").arg(mEditor->fps());
}

// ── Qt Bridge Functions (C ABI, called from Zig) ─────────────────────
// Each casts void* editor to Editor*, calls Qt API.
// These run on the main thread via McpHandler's BlockingQueuedConnection.

extern "C" {

int qt_editor_layer_count(void* editor) {
    auto* e = static_cast<Editor*>(editor);
    return e->object() ? e->object()->getLayerCount() : 0;
}

int qt_editor_get_layer(void* editor, int index, EditorLayerInfo* out) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object() || index < 0 || index >= e->object()->getLayerCount()) return -1;
    Layer* layer = e->object()->getLayer(index);
    out->id = layer->id();
    out->index = index;
    out->keyframe_count = layer->keyFrameCount();
    out->layer_type = static_cast<int>(layer->type());
    out->visible = layer->visible() ? 1 : 0;
    QByteArray name = layer->name().toUtf8();
    int len = qMin(name.size(), 255);
    memcpy(out->name, name.constData(), len);
    out->name[len] = 0;
    return 0;
}

int qt_editor_get_keyframes(void* editor, int layer_index,
                            EditorKeyframeInfo* out, int max_count) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return 0;
    Layer* layer = e->object()->getLayer(layer_index);
    if (!layer) return 0;
    int count = 0;
    layer->foreachKeyFrame([&](KeyFrame* kf) {
        if (count < max_count) {
            out[count].frame = kf->pos();
            out[count].length = kf->length();
            count++;
        }
    });
    return count;
}

int qt_editor_current_frame(void* editor) {
    return static_cast<Editor*>(editor)->currentFrame();
}

int qt_editor_fps(void* editor) {
    return static_cast<Editor*>(editor)->fps();
}

int qt_editor_scrub_to(void* editor, int frame) {
    static_cast<Editor*>(editor)->scrubTo(frame);
    return static_cast<Editor*>(editor)->currentFrame();
}

int qt_editor_add_layer(void* editor, const char* name, int type) {
    auto* e = static_cast<Editor*>(editor);
    Layer* layer = nullptr;
    QString qName = QString::fromUtf8(name);
    switch (type) {
        case 1: layer = e->layers()->createBitmapLayer(qName); break;
        case 2: layer = e->layers()->createVectorLayer(qName); break;
        case 5: layer = e->layers()->createCameraLayer(qName); break;
        case 4: layer = e->layers()->createSoundLayer(qName); break;
        default: return -1;
    }
    if (!layer) return -1;
    emit e->updateTimeLine();
    return layer->id();
}

int qt_editor_remove_layer(void* editor, int index) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object() || e->object()->getLayerCount() <= 1) return -1;
    e->object()->deleteLayer(index);
    emit e->updateTimeLine();
    emit e->updateLayerCount();
    return 0;
}

int qt_editor_rename_layer(void* editor, int index, const char* name) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return -1;
    Layer* layer = e->object()->getLayer(index);
    if (!layer) return -1;
    layer->setName(QString::fromUtf8(name));
    emit e->updateTimeLine();
    return 0;
}

int qt_editor_set_layer_visibility(void* editor, int index, int visible) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return -1;
    Layer* layer = e->object()->getLayer(index);
    if (!layer) return -1;
    if (visible >= 0) layer->setVisible(visible != 0);
    else layer->switchVisibility();
    e->updateFrame();
    return layer->visible() ? 1 : 0;
}

int qt_editor_add_keyframe(void* editor, int layer_index, int frame) {
    auto* e = static_cast<Editor*>(editor);
    KeyFrame* kf = e->addKeyFrame(layer_index, frame);
    emit e->updateTimeLine();
    e->updateFrame();
    return kf ? kf->pos() : -1;
}

int qt_editor_remove_keyframe(void* editor, int layer_index, int frame) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return -1;
    Layer* layer = e->object()->getLayer(layer_index);
    if (!layer || !layer->keyExists(frame)) return -1;
    layer->removeKeyFrame(frame);
    emit e->updateTimeLine();
    e->updateFrame();
    return 0;
}

int qt_editor_play(void* editor) {
    static_cast<Editor*>(editor)->playback()->play();
    return 0;
}

int qt_editor_stop(void* editor) {
    static_cast<Editor*>(editor)->playback()->stop();
    return static_cast<Editor*>(editor)->currentFrame();
}

int qt_editor_set_fps(void* editor, int fps) {
    auto* e = static_cast<Editor*>(editor);
    e->setFps(fps);
    return e->fps();
}

int qt_editor_set_color(void* editor, int r, int g, int b, int a) {
    static_cast<Editor*>(editor)->color()->setFrontColor(QColor(r, g, b, a));
    return 0;
}

int qt_editor_set_tool(void* editor, int tool_type) {
    static_cast<Editor*>(editor)->tools()->setCurrentTool(static_cast<ToolType>(tool_type));
    return 0;
}

int qt_editor_draw_rect(void* editor, int layer, int x, int y, int w, int h,
                        int r, int g, int b, int a) {
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    img->drawRect(QRectF(x, y, w, h), QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                  QPainter::CompositionMode_SourceOver, false);
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

int qt_editor_draw_circle(void* editor, int layer, int cx, int cy, int radius,
                          int r, int g, int b, int a) {
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    img->drawEllipse(QRectF(cx - radius, cy - radius, radius * 2, radius * 2),
                     QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                     QPainter::CompositionMode_SourceOver, false);
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

int qt_editor_draw_line(void* editor, int layer, int x0, int y0, int x1, int y1,
                        int r, int g, int b, int a, int width) {
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    QPen pen(QColor(r, g, b, a), width, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
    img->drawLine(QPointF(x0, y0), QPointF(x1, y1), pen,
                  QPainter::CompositionMode_SourceOver, false);
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

int qt_editor_clear_frame(void* editor, int layer) {
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    img->clear();
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

} // extern "C"
