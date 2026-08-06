import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RemoteContent {
    public static let maximumDownloadBytes = 32 * 1024 * 1024

    public static func inlineUnsupportedURLs(
        in messages: [Message],
        model: any LanguageModel,
        urlSession: URLSession = .shared
    ) async throws -> [Message] {
        var messages = messages
        for messageIndex in messages.indices {
            for partIndex in messages[messageIndex].content.indices {
                switch messages[messageIndex].content[partIndex] {
                case .image(var image):
                    guard let url = image.url, image.data == nil,
                          image.providerReference.isEmpty,
                          !isInlineable(url),
                          !model.supportsRemoteURL(url, mediaType: image.mediaType)
                    else { continue }
                    let downloaded = try await download(url, urlSession: urlSession)
                    image.data = downloaded.data
                    image.url = nil
                    image.mediaType = image.mediaType ?? downloaded.mediaType
                    messages[messageIndex].content[partIndex] = .image(image)

                case .file(var file):
                    guard let url = file.url, file.data == nil,
                          file.providerReference.isEmpty,
                          !isInlineable(url),
                          !model.supportsRemoteURL(url, mediaType: file.mediaType)
                    else { continue }
                    let downloaded = try await download(url, urlSession: urlSession)
                    file.data = downloaded.data
                    file.url = nil
                    if file.mediaType.isEmpty || file.mediaType == "application/octet-stream",
                       let mediaType = downloaded.mediaType {
                        file.mediaType = mediaType
                    }
                    messages[messageIndex].content[partIndex] = .file(file)

                default:
                    continue
                }
            }
        }
        return messages
    }

    static func isInlineable(_ url: URL) -> Bool {
        url.scheme == "data"
    }

    static func download(
        _ url: URL, urlSession: URLSession
    ) async throws -> (data: Data, mediaType: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AIError.invalidRequest(
                "Cannot download \(url.absoluteString): only http(s) URLs are fetched"
            )
        }

        let (stream, response) = try await urlSession.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(
                status: http.statusCode,
                body: "Failed to download \(url.absoluteString)"
            )
        }

        // A declared length lets an oversize body be refused before a single
        // byte is read.
        if response.expectedContentLength > Int64(maximumDownloadBytes) {
            throw oversize(url)
        }

        // Read incrementally and stop at the limit, rather than buffering the
        // whole body and measuring it afterwards.
        var data = Data()
        data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), maximumDownloadBytes))
        for try await byte in stream {
            data.append(byte)
            if data.count > maximumDownloadBytes { throw oversize(url) }
        }
        return (data, response.mimeType)
    }

    static func oversize(_ url: URL) -> AIError {
        AIError.invalidRequest(
            "Downloaded content for \(url.absoluteString) exceeds "
            + "\(maximumDownloadBytes) bytes"
        )
    }
}
