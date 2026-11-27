import Foundation
import NMCore
import SwiftUI
import UniformTypeIdentifiers

public struct FieldProjectDocument: FileDocument, Sendable {
    public static let contentType = UTType(exportedAs: "net.borntoberoot.networkmanager.macos.field-project", conformingTo: .json)
    public static let readableContentTypes = [contentType]
    var project: FieldProject

    public init() { project = FieldProject() }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedFailureReasonErrorKey: t("The field project is damaged or has an invalid format.")
            ])
        }
        do {
            project = try FieldProject.decode(data)
        } catch {
            // DocumentGroup uses the Cocoa failure reason when presenting read errors.
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedFailureReasonErrorKey: error.localizedDescription
            ])
        }
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        do {
            return try FileWrapper(regularFileWithContents: project.encoded())
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedFailureReasonErrorKey: error.localizedDescription
            ])
        }
    }
}

struct FieldProjectReport: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
