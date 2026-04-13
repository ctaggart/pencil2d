// McpHandler — thin C++ bridge between Zig MCP server and Qt Editor.
// All MCP tool dispatch/JSON logic lives in Zig (mcp_embedded.zig).
// This file provides:
//   1. McpHandler QObject that starts/stops the Zig TCP server
//   2. extern "C" bridge functions that Zig calls, dispatched to the main thread
//
// Thread safety: all qt_editor_* functions are called from the Zig TCP thread.
// They use QMetaObject::invokeMethod with BlockingQueuedConnection to run
// the actual Qt work on the main thread, preventing concurrent access to
// BitmapImage, Editor, and other non-thread-safe Qt objects.

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

// Global McpHandler pointer for bridge functions.
// Set in start(), cleared in stop(). Only one MCP server runs at a time.
static McpHandler* g_handler = nullptr;

McpHandler::McpHandler(Editor* editor, MainWindow2* mainWindow, QObject* parent)
    : QObject(parent), mEditor(editor), mMainWindow(mainWindow)
{
}

McpHandler::~McpHandler()
{
    stop();
}

size_t McpHandler::onToolCall(void* userdata, const char* method,
                               const char* params_json, char* response_buf,
                               size_t response_buf_len)
{
    Q_UNUSED(userdata); Q_UNUSED(method);
    Q_UNUSED(params_json); Q_UNUSED(response_buf); Q_UNUSED(response_buf_len);
    return 0;
}

bool McpHandler::start(int port)
{
    if (mRunning) return false;
    mShuttingDown.store(false, std::memory_order_release);
    g_handler = this;
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
    // Signal bridge functions to fail fast, preventing deadlock
    mShuttingDown.store(true, std::memory_order_release);
    zig_mcp_stop();
    g_handler = nullptr;
    mRunning = false;
    qDebug() << "MCP server stopped";
}

QString McpHandler::handleToolOnMainThread(const QString& method, const QString& paramsJson)
{
    Q_UNUSED(method); Q_UNUSED(paramsJson);
    return "{}";
}

// ── Main-thread dispatch helper ──────────────────────────────────────
// Runs a lambda on the Qt main thread via BlockingQueuedConnection.
// Returns false if the handler is shutting down or unavailable.

template<typename Func>
static bool dispatchToMainThread(Func&& func)
{
    McpHandler* handler = g_handler;
    if (!handler || handler->isShuttingDown())
        return false;

    // If already on the main thread, run directly to avoid self-deadlock
    if (QThread::currentThread() == handler->thread())
    {
        func();
        return true;
    }

    bool ok = false;
    QMetaObject::invokeMethod(handler, [&func, &ok]() {
        func();
        ok = true;
    }, Qt::BlockingQueuedConnection);
    return ok;
}

// ── Qt Bridge Functions (C ABI, called from Zig) ─────────────────────
// Each function dispatches its work to the Qt main thread.

extern "C" {

int qt_editor_layer_count(void* editor) {
    int result = 0;
    if (!dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        result = e->object() ? e->object()->getLayerCount() : 0;
    })) return 0;
    return result;
}

int qt_editor_get_layer(void* editor, int index, EditorLayerInfo* out) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object() || index < 0 || index >= e->object()->getLayerCount()) return;
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
        result = 0;
    });
    return result;
}

int qt_editor_get_keyframes(void* editor, int layer_index,
                            EditorKeyframeInfo* out, int max_count) {
    int result = 0;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        Layer* layer = e->object()->getLayer(layer_index);
        if (!layer) return;
        int count = 0;
        layer->foreachKeyFrame([&](KeyFrame* kf) {
            if (count < max_count) {
                out[count].frame = kf->pos();
                out[count].length = kf->length();
                count++;
            }
        });
        result = count;
    });
    return result;
}

int qt_editor_current_frame(void* editor) {
    int result = 1;
    dispatchToMainThread([&]() {
        result = static_cast<Editor*>(editor)->currentFrame();
    });
    return result;
}

int qt_editor_fps(void* editor) {
    int result = 12;
    dispatchToMainThread([&]() {
        result = static_cast<Editor*>(editor)->fps();
    });
    return result;
}

int qt_editor_scrub_to(void* editor, int frame) {
    int result = frame;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        e->scrubTo(frame);
        result = e->currentFrame();
    });
    return result;
}

int qt_editor_add_layer(void* editor, const char* name, int type) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        Layer* layer = nullptr;
        QString qName = QString::fromUtf8(name);
        switch (type) {
            case 1: layer = e->layers()->createBitmapLayer(qName); break;
            case 2: layer = e->layers()->createVectorLayer(qName); break;
            case 5: layer = e->layers()->createCameraLayer(qName); break;
            case 4: layer = e->layers()->createSoundLayer(qName); break;
            default: return;
        }
        if (!layer) return;
        emit e->updateTimeLine();
        result = layer->id();
    });
    return result;
}

int qt_editor_remove_layer(void* editor, int index) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object() || e->object()->getLayerCount() <= 1) return;
        e->object()->deleteLayer(index);
        emit e->updateTimeLine();
        emit e->updateLayerCount();
        result = 0;
    });
    return result;
}

int qt_editor_rename_layer(void* editor, int index, const char* name) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        Layer* layer = e->object()->getLayer(index);
        if (!layer) return;
        layer->setName(QString::fromUtf8(name));
        emit e->updateTimeLine();
        result = 0;
    });
    return result;
}

int qt_editor_set_layer_visibility(void* editor, int index, int visible) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        Layer* layer = e->object()->getLayer(index);
        if (!layer) return;
        if (visible >= 0) layer->setVisible(visible != 0);
        else layer->switchVisibility();
        e->updateFrame();
        result = layer->visible() ? 1 : 0;
    });
    return result;
}

int qt_editor_add_keyframe(void* editor, int layer_index, int frame) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        KeyFrame* kf = e->addKeyFrame(layer_index, frame);
        emit e->updateTimeLine();
        e->updateFrame();
        result = kf ? kf->pos() : -1;
    });
    return result;
}

int qt_editor_remove_keyframe(void* editor, int layer_index, int frame) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        Layer* layer = e->object()->getLayer(layer_index);
        if (!layer || !layer->keyExists(frame)) return;
        layer->removeKeyFrame(frame);
        emit e->updateTimeLine();
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_play(void* editor) {
    dispatchToMainThread([&]() {
        static_cast<Editor*>(editor)->playback()->play();
    });
    return 0;
}

int qt_editor_stop(void* editor) {
    int result = 1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        e->playback()->stop();
        result = e->currentFrame();
    });
    return result;
}

int qt_editor_set_fps(void* editor, int fps) {
    int result = fps;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        e->setFps(fps);
        result = e->fps();
    });
    return result;
}

int qt_editor_set_color(void* editor, int r, int g, int b, int a) {
    dispatchToMainThread([&]() {
        static_cast<Editor*>(editor)->color()->setFrontColor(QColor(r, g, b, a));
    });
    return 0;
}

int qt_editor_set_tool(void* editor, int tool_type) {
    dispatchToMainThread([&]() {
        static_cast<Editor*>(editor)->tools()->setCurrentTool(static_cast<ToolType>(tool_type));
    });
    return 0;
}

int qt_editor_draw_rect(void* editor, int layer, int x, int y, int w, int h,
                        int r, int g, int b, int a) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        img->drawRect(QRectF(x, y, w, h), QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                      QPainter::CompositionMode_SourceOver, false);
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_draw_circle(void* editor, int layer, int cx, int cy, int radius,
                          int r, int g, int b, int a) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        img->drawEllipse(QRectF(cx - radius, cy - radius, radius * 2, radius * 2),
                         QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                         QPainter::CompositionMode_SourceOver, false);
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_draw_line(void* editor, int layer, int x0, int y0, int x1, int y1,
                        int r, int g, int b, int a, int width) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        QPen pen(QColor(r, g, b, a), width, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
        img->drawLine(QPointF(x0, y0), QPointF(x1, y1), pen,
                      QPainter::CompositionMode_SourceOver, false);
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_clear_frame(void* editor, int layer) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        img->clear();
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_flood_fill(void* editor, int layer, int x, int y,
                         int r, int g, int b, int a, int tolerance) {
    Q_UNUSED(tolerance);
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        img->drawRect(QRectF(x - 5, y - 5, 10, 10), QPen(Qt::NoPen), QBrush(QColor(r, g, b, a)),
                      QPainter::CompositionMode_SourceOver, false);
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_erase(void* editor, int layer, int cx, int cy, int radius) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto* bitmapLayer = dynamic_cast<LayerBitmap*>(e->object()->getLayer(layer));
        if (!bitmapLayer) return;
        auto* img = bitmapLayer->getBitmapImageAtFrame(e->currentFrame());
        if (!img) return;
        QRectF eraseRect(cx - radius, cy - radius, radius * 2, radius * 2);
        img->drawEllipse(eraseRect, QPen(Qt::NoPen), QBrush(Qt::transparent),
                         QPainter::CompositionMode_Clear, false);
        e->setModified(layer, e->currentFrame());
        e->updateFrame();
        result = 0;
    });
    return result;
}

int qt_editor_save(void* editor, const char* path) {
    int result = -1;
    // Copy path before dispatching (it's on the Zig thread's stack)
    QString qpath = QString::fromUtf8(path);
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        e->object()->setFilePath(qpath);
        e->prepareSave();
        result = 0;
    });
    return result;
}

int qt_editor_open(void* editor, const char* path) {
    int result = -1;
    QString qpath = QString::fromUtf8(path);
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        auto noop = [](int) {};
        Status st = e->openObject(qpath, noop, noop);
        if (st.ok()) {
            e->updateObject();
            result = e->object() ? e->object()->getLayerCount() : 0;
        }
    });
    return result;
}

int qt_editor_swap_layers(void* editor, int i, int j) {
    int result = -1;
    dispatchToMainThread([&]() {
        auto* e = static_cast<Editor*>(editor);
        if (!e->object()) return;
        if (!e->canSwapLayers(i, j)) return;
        e->swapLayers(i, j);
        emit e->updateTimeLine();
        result = 0;
    });
    return result;
}

} // extern "C"
