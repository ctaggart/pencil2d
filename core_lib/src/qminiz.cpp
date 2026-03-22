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
#include "qminiz.h"

#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QDebug>
#include "util.h"


Status MiniZ::sanityCheck(const QString& sZipFilePath)
{
    DebugDetails dd;
    dd << "\n[Zig ZIP sanity check]\n";

    QFile file(sZipFilePath);
    if (!file.open(QIODevice::ReadOnly))
    {
        dd << QString("Error: Cannot open file: %1").arg(sZipFilePath);
        return Status(Status::ERROR_MINIZ_FAIL, dd);
    }

    QByteArray data = file.readAll();
    file.close();

    int result = zig_zip_validate(
        reinterpret_cast<const unsigned char*>(data.constData()),
        static_cast<size_t>(data.size()));

    if (result != 0)
    {
        dd << QString("Error: ZIP validation failed for: %1").arg(sZipFilePath);
        return Status(Status::ERROR_MINIZ_FAIL, dd);
    }

    return Status::OK;
}

Status MiniZ::compressFolder(QString zipFilePath, QString srcFolderPath, const QStringList& fileList, QString mimetype)
{
    DebugDetails dd;
    dd << "\n[Zig ZIP COMPRESSION diagnostics]\n";
    dd << QString("Creating Zip %1 from folder %2").arg(zipFilePath, srcFolderPath);

    if (!srcFolderPath.endsWith("/"))
    {
        srcFolderPath.append("/");
    }

    void* writer = zig_zip_writer_create();
    if (!writer)
    {
        dd << "Error: Failed to create ZIP writer";
        return Status(Status::FAIL, dd);
    }
    ScopeGuard writerGuard([&] {
        zig_zip_writer_destroy(writer);
    });

    // Add uncompressed mimetype entry first
    {
        QByteArray mimeData = mimetype.toUtf8();
        int ok = zig_zip_writer_add_bytes(writer, "mimetype",
            reinterpret_cast<const unsigned char*>(mimeData.constData()),
            static_cast<size_t>(mimeData.size()), false);
        if (ok != 0)
        {
            dd << "Error: Unable to add mimetype entry";
            return Status(Status::FAIL, dd);
        }
    }

    for (const QString& filePath : fileList)
    {
        QString sRelativePath = filePath;
        sRelativePath.remove(srcFolderPath);
        if (sRelativePath == "mimetype") continue;

        dd << QString("Add file to zip: ").append(sRelativePath);

        QFile srcFile(filePath);
        if (!srcFile.open(QIODevice::ReadOnly))
        {
            dd << QString("Error: Cannot open source file: %1 - Aborting!").arg(filePath);
            return Status(Status::FAIL, dd);
        }
        QByteArray fileData = srcFile.readAll();
        srcFile.close();

        QByteArray nameUtf8 = sRelativePath.toUtf8();
        int ok = zig_zip_writer_add_bytes(writer, nameUtf8.constData(),
            reinterpret_cast<const unsigned char*>(fileData.constData()),
            static_cast<size_t>(fileData.size()), true);
        if (ok != 0)
        {
            dd << QString("Error: Unable to add file: %1 - Aborting!").arg(sRelativePath);
            return Status(Status::FAIL, dd);
        }
    }

    if (zig_zip_writer_finalize(writer) != 0)
    {
        dd << "Error: Failed to finalize archive";
        return Status(Status::FAIL, dd);
    }

    // Get the completed ZIP data and write to disk
    const unsigned char* zipData = nullptr;
    size_t zipLen = 0;
    if (zig_zip_writer_get_data(writer, &zipData, &zipLen) != 0)
    {
        dd << "Error: Failed to get ZIP data";
        return Status(Status::FAIL, dd);
    }

    QFile outFile(zipFilePath);
    if (!outFile.open(QIODevice::WriteOnly))
    {
        dd << QString("Error: Cannot create output file: %1").arg(zipFilePath);
        return Status(Status::FAIL, dd);
    }
    qint64 written = outFile.write(reinterpret_cast<const char*>(zipData),
                                   static_cast<qint64>(zipLen));
    outFile.close();

    if (written != static_cast<qint64>(zipLen))
    {
        dd << "Error: Failed to write ZIP file to disk";
        return Status(Status::FAIL, dd);
    }

    return Status::OK;
}

Status MiniZ::uncompressFolder(QString zipFilePath, QString destPath)
{
    DebugDetails dd;
    dd << "\n[Zig ZIP EXTRACTION diagnostics]\n";
    dd << QString("Unzip file %1 to folder %2").arg(zipFilePath, destPath);

    if (!QFile::exists(zipFilePath))
    {
        dd << QString("Error: Zip file does not exist.");
        return Status::FILE_NOT_FOUND;
    }

    // Read the entire ZIP file into memory
    QFile zipFile(zipFilePath);
    if (!zipFile.open(QIODevice::ReadOnly))
    {
        dd << QString("Error: Cannot open ZIP file: %1").arg(zipFilePath);
        return Status(Status::FAIL, dd);
    }
    QByteArray zipData = zipFile.readAll();
    zipFile.close();

    // Ensure destination directory exists
    QString sBaseDir = QFileInfo(destPath).absolutePath();
    QDir baseDir(sBaseDir);
    if (!baseDir.exists())
    {
        bool ok = baseDir.mkpath(".");
        Q_ASSERT(ok);
    }
    baseDir.makeAbsolute();

    // Open ZIP reader from memory
    void* reader = zig_zip_reader_open(
        reinterpret_cast<const unsigned char*>(zipData.constData()),
        static_cast<size_t>(zipData.size()));
    if (!reader)
    {
        dd << "Error: Failed to open ZIP reader";
        return Status(Status::FAIL, dd);
    }
    ScopeGuard readerGuard([&] {
        zig_zip_reader_destroy(reader);
    });

    int numEntries = zig_zip_reader_count(reader);
    bool ok = true;

    // First pass: create directories
    for (int i = 0; i < numEntries; ++i)
    {
        if (zig_zip_reader_entry_is_dir(reader, i))
        {
            const char* namePtr = nullptr;
            size_t nameLen = 0;
            if (zig_zip_reader_entry_name(reader, i, &namePtr, &nameLen) != 0)
                continue;

            QString dirName = QString::fromUtf8(namePtr, static_cast<int>(nameLen));
            dd << QString("Make Dir: ").append(dirName);

            bool mkDirOK = baseDir.mkpath(dirName);
            Q_ASSERT(mkDirOK);
            if (!mkDirOK)
                dd << "Make Dir failed.";
        }
    }

    // Second pass: extract files
    for (int i = 0; i < numEntries; ++i)
    {
        if (zig_zip_reader_entry_is_dir(reader, i))
            continue;

        const char* namePtr = nullptr;
        size_t nameLen = 0;
        if (zig_zip_reader_entry_name(reader, i, &namePtr, &nameLen) != 0)
        {
            ok = false;
            continue;
        }

        QString entryName = QString::fromUtf8(namePtr, static_cast<int>(nameLen));
        if (entryName == "mimetype") continue;

        QString sFullPath = baseDir.filePath(entryName);
        dd << QString("Unzip file: ").append(sFullPath);

        // Ensure parent directory exists
        bool b = QFileInfo(sFullPath).absoluteDir().mkpath(".");
        Q_ASSERT(b);

        // Extract entry data
        unsigned char* entryData = nullptr;
        size_t entryLen = 0;
        if (zig_zip_reader_extract(reader, i, &entryData, &entryLen) != 0)
        {
            ok = false;
            dd << QString("WARNING: Unable to extract file: %1").arg(entryName);
            continue;
        }

        // Write to disk
        QFile outFile(sFullPath);
        if (outFile.open(QIODevice::WriteOnly))
        {
            outFile.write(reinterpret_cast<const char*>(entryData),
                         static_cast<qint64>(entryLen));
            outFile.close();
        }
        else
        {
            ok = false;
            dd << QString("WARNING: Unable to write file: %1").arg(sFullPath);
        }

        // Free the extracted data
        zig_free(entryData, entryLen);
    }

    if (!ok)
    {
        return Status(Status::FAIL, dd);
    }
    return Status::OK;
}
