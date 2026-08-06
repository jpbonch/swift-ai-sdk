import Foundation

public protocol ImageModel: Sendable {
    var provider: String { get }
    var modelID: String { get }
    func generateImages(_ request: ImageModelRequest) async throws -> ImageModelResponse
}

public struct ImageModelRequest: Sendable {
    public var prompt: String
    public var images: [ImageContent]
    public var n: Int
    public var size: String?
    public var aspectRatio: String?
    public var seed: Int?
    public var providerOptions: JSONValue?

    public init(
        prompt: String,
        images: [ImageContent] = [],
        n: Int = 1,
        size: String? = nil,
        aspectRatio: String? = nil,
        seed: Int? = nil,
        providerOptions: JSONValue? = nil
    ) {
        self.prompt = prompt
        self.images = images
        self.n = n
        self.size = size
        self.aspectRatio = aspectRatio
        self.seed = seed
        self.providerOptions = providerOptions
    }
}

public struct ImageModelResponse: Sendable {
    public var images: [Data]
    public var revisedPrompts: [String?]
    /// Providers that report what they encoded should set this. When they
    /// don't, `generateImage` reads it off the bytes.
    public var mediaType: String?

    public init(
        images: [Data], revisedPrompts: [String?] = [], mediaType: String? = nil
    ) {
        self.images = images
        self.revisedPrompts = revisedPrompts
        self.mediaType = mediaType
    }
}

public func detectImageMediaType(_ image: Data) -> String? {
    let bytes = [UInt8](image.prefix(12))

    func matches(_ ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard bytes.count >= offset + expected.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }

    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
    if matches("RIFF", at: 0), matches("WEBP", at: 8) { return "image/webp" }
    if matches("ftyp", at: 4) {
        for brand in ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"]
        where matches(brand, at: 8) {
            return "image/heic"
        }
        for brand in ["avif", "avis"] where matches(brand, at: 8) {
            return "image/avif"
        }
        return nil
    }
    if bytes.starts(with: [0x42, 0x4D]) { return "image/bmp" }
    return nil
}

public struct GenerateImageResult: Sendable {
    public var image: Data
    public var images: [Data]
    public var revisedPrompts: [String?]
    public var mediaType: String = "image/png"

    public var file: GeneratedFile {
        GeneratedFile(data: image, mediaType: mediaType)
    }

    public var files: [GeneratedFile] {
        images.map { GeneratedFile(data: $0, mediaType: mediaType) }
    }
}

public func generateImage(
    model: any ImageModel,
    prompt: String,
    images: [ImageContent] = [],
    n: Int = 1,
    size: String? = nil,
    aspectRatio: String? = nil,
    seed: Int? = nil,
    providerOptions: JSONValue? = nil,
    maxImagesPerCall: Int? = nil,
    maxRetries: Int = 2
) async throws -> GenerateImageResult {
    let perCall = max(1, maxImagesPerCall ?? n)
    var allImages: [Data] = []
    var allRevised: [String?] = []
    var reportedMediaType: String?
    var remaining = max(1, n)
    while remaining > 0 {
        let batch = Swift.min(perCall, remaining)
        let request = ImageModelRequest(
            prompt: prompt, images: images, n: batch, size: size,
            aspectRatio: aspectRatio, seed: seed, providerOptions: providerOptions
        )
        let response = try await Retry.withRetries(maxRetries) {
            try await model.generateImages(request)
        }
        allImages += response.images
        allRevised += response.revisedPrompts
        reportedMediaType = reportedMediaType ?? response.mediaType
        remaining -= batch
    }
    guard let first = allImages.first else {
        throw AIError.decoding("Image response contained no images")
    }
    return GenerateImageResult(
        image: first,
        images: allImages,
        revisedPrompts: allRevised,
        mediaType: reportedMediaType ?? detectImageMediaType(first) ?? "image/png"
    )
}
