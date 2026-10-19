import AppKit
import SwiftUI
import TavernCore
import UniformTypeIdentifiers

/// An image waiting in a message box: dropped, pasted or picked.
struct DraftImage: Identifiable, Equatable {
    let id = UUID()
    var data: Data
    var mimeType: String
    var thumbnail: NSImage

    var piImage: PiImage { PiImage(data: data, mimeType: mimeType) }

    /// Reads an image file. Big photos are scaled to 2048 px and sent as JPEG to keep messages small.
    static func load(_ url: URL) -> DraftImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        if data.count < 3_000_000, let mime = type.preferredMIMEType, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
            return DraftImage(data: data, mimeType: mime, thumbnail: image)
        }
        return from(image)
    }

    static func from(_ image: NSImage) -> DraftImage? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 2048 ? 2048 / longest : 1
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return DraftImage(data: jpeg, mimeType: "image/jpeg", thumbnail: image)
    }

    /// Images on the pasteboard: copied image data, or image files copied in Finder.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [DraftImage] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.compactMap(load)
            if !images.isEmpty { return images }
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(from)
    }
}

extension View {
    /// Accepts image files and images dragged onto the view, highlighting while one is over it.
    func acceptsImageDrops(into images: Binding<[DraftImage]>, targeted: Binding<Bool>) -> some View {
        onDrop(of: [.fileURL, .image], isTargeted: targeted) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, let image = DraftImage.load(url) else { return }
                        DispatchQueue.main.async { images.wrappedValue.append(image) }
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                        guard let nsImage = object as? NSImage, let image = DraftImage.from(nsImage) else { return }
                        DispatchQueue.main.async { images.wrappedValue.append(image) }
                    }
                }
            }
            return true
        }
    }
}

/// Thumbnails of the images in a message box, each with a remove button.
struct AttachmentTray: View {
    @Binding var images: [DraftImage]

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        Image(nsImage: image.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Button { images.removeAll { $0.id == image.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .help("Remove")
                            }
                    }
                }
            }
        }
    }
}

/// The "+" that opens a file picker for images.
struct AddImageButton: View {
    @Binding var images: [DraftImage]
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add images (or drop or paste them)")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                if let image = DraftImage.load(url) { images.append(image) }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
}
