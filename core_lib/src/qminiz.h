/*

Pencil2D - Traditional Animation Software
Copyright (C) 2012-2020 Matthew Chiawen Chang

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; version 2 of the License.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

*/
#ifndef QMINIZ_H
#define QMINIZ_H

#include <QString>
#include "pencilerror.h"

// Zig ZIP C ABI
extern "C" {
    void* zig_zip_writer_create();
    int   zig_zip_writer_add_bytes(void* handle, const char* name, const unsigned char* data, size_t len, bool compress);
    int   zig_zip_writer_finalize(void* handle);
    int   zig_zip_writer_get_data(void* handle, const unsigned char** out_data, size_t* out_len);
    void  zig_zip_writer_destroy(void* handle);

    void* zig_zip_reader_open(const unsigned char* data, size_t len);
    int   zig_zip_reader_count(void* handle);
    int   zig_zip_reader_entry_name(void* handle, int index, const char** out_name, size_t* out_len);
    int   zig_zip_reader_entry_is_dir(void* handle, int index);
    int   zig_zip_reader_extract(void* handle, int index, unsigned char** out_data, size_t* out_len);
    void  zig_zip_reader_destroy(void* handle);

    int   zig_zip_validate(const unsigned char* data, size_t len);
    void  zig_free(unsigned char* ptr, size_t len);
}

namespace MiniZ
{
    Status sanityCheck(const QString& sZipFilePath);
    Status compressFolder(QString zipFilePath, QString srcFolderPath, const QStringList& fileList, QString mimetype);
    Status uncompressFolder(QString zipFilePath, QString destPath);
}
#endif
