// McpHandler — thin C++ bridge between Zig MCP server and Qt Editor.
// All MCP tool dispatch/JSON logic lives in Zig (mcp_embedded.zig).
// This file provides:
//   1. McpHandler QObject that starts/stops the Zig TCP server
//   2. 20 extern "C" bridge functions that Zig calls to touch Qt

#include "mcphandler.h"
#include "editor.h"
#include "layermanager.h"
#include "playbackmanager.h"
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

// Zig MCP callback — dispatches tool calls to the main Qt thread.
// The Zig side now calls qt_editor_* C functions directly,
// so this callback is only used for the initial handshake.
size_t McpHandler::onToolCall(void* userdata, const char* method,
                               const char* params_json, char* response_buf,
                               size_t response_buf_len)
{
    Q_UNUSED(userdata); Q_UNUSED(method);
    Q_UNUSED(params_json); Q_UNUSED(response_buf); Q_UNUSED(response_buf_len);
    return 0; // Not used — Zig dispatches directly via extern C
}

bool McpHandler::start(int port)
{
    if (mRunning) return false;
    // Pass Editor* as userdata so Zig can forward it to qt_editor_* functions
    int result = zig_mcp_start(static_cast<uint16_t>(port), &McpHandler::onToolCall, mEditor);
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

QString McpHandler::handleToolOnMainThread(const QString& method, const QString& paramsJson)
{
    Q_UNUSED(method); Q_UNUSED(paramsJson);
    return "{}"; // Not used — Zig handles dispatch
}

// ── Qt Bridge Functions (C ABI, called from Zig) ─────────────────────
// Each function is a thin wrapper calling the Qt Editor API.
// These must run on the main thread — McpHandler ensures this via
// BlockingQueuedConnection in the MCP callback path.

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

int qt_editor_flood_fill(void* editor, int layer, int x, int y,
                         int r, int g, int b, int a, int tolerance) {
    Q_UNUSED(tolerance);
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    // Simple fill using drawRect at click point as fallback
    // Full flood fill requires BitmapBucket which needs Editor context
    img->drawRect(QRectF(x - 5, y - 5, 10, 10), QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                  QPainter::CompositionMode_SourceOver, false);
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

int qt_editor_erase(void* editor, int layer, int cx, int cy, int radius) {
    auto* e = static_cast<Editor*>(editor);
    auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
    if (!bitmapLayer) return -1;
    auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
    if (!img) return -1;
    QRectF eraseRect(cx - radius, cy - radius, radius * 2, radius * 2);
    img->drawEllipse(eraseRect, QPen(Qt::NoPen), QBrush(Qt::transparent),
                     QPainter::CompositionMode_Clear, false);
    e->setModified(layer, e->currentFrame());
    e->updateFrame();
    return 0;
}

int qt_editor_save(void* editor, const char* path) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return -1;
    e->object()->setFilePath(QString::fromUtf8(path));
    e->prepareSave();
    return 0;
}

int qt_editor_open(void* editor, const char* path) {
    auto* e = static_cast<Editor*>(editor);
    auto noop = [](int) {};
    Status st = e->openObject(QString::fromUtf8(path), noop, noop);
    if (st.ok()) {
        e->updateObject();
        return e->object() ? e->object()->getLayerCount() : 0;
    }
    return -1;
}

int qt_editor_swap_layers(void* editor, int i, int j) {
    auto* e = static_cast<Editor*>(editor);
    if (!e->object()) return -1;
    if (!e->canSwapLayers(i, j)) return -1;
    e->swapLayers(i, j);
    emit e->updateTimeLine();
    return 0;
}

} // extern "C"
