//
//  StreamResourceLoader.swift
//  Coda
//
//  Created by Coda on 16/10/26.
//

import Foundation
import AVFoundation

public final class StreamResourceLoader: NSObject {

    // MARK: - Configuration

    public static var isEnabled = true
    public static var log: ((String) -> Void)?
    // Empty means every http(s) host; otherwise only these lowercase hosts go through the loader
    public static var allowedHosts: Set<String> = []
    static let scheme = "codastream"
    static let maxLiveLoaders = 4
    static let maxResumeAttempts = 3

    // MARK: - Variables

    private static let filePrefix = "codastream-"
    private static let registryQueue = DispatchQueue(label: "StreamResourceLoader.registry")
    private static var registry: [ObjectIdentifier: StreamResourceLoader] = [:]
    private static var registryOrder: [ObjectIdentifier] = []
    // Runs once before the first loader writes, so any file found is left over from a crash or kill in an earlier launch
    private static let removeStaleFiles: Void = {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(StreamResourceLoader.filePrefix) {
            try? fileManager.removeItem(at: file)
        }
    }()

    let queue = DispatchQueue(label: "StreamResourceLoader.work")
    private let originalURL: URL
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var received: Int64 = 0
    private var requestOffset: Int64 = 0
    private var resumeAttempts = 0
    // AVFoundation fails with -1, so this stays unknown until Content-Length, the MP4 mdat header, or the finished download gives it
    private var knownLength: Int64 = -1
    private var lengthProbeOffset: Int64 = 0
    private var lengthProbeSawMoov = false
    private var lengthProbeGaveUp = false
    private var mimeType: String?
    private var httpStatus = 0
    private var finished = false
    private var invalidated = false
    private var failure: Error?

    enum StreamError: Error {
        case cancelled
        case badStatus(Int)
        case resumeRejected(Int)
        case truncated
        case fileUnavailable
    }

    // MARK: - Factory

    public static func shouldHandle(_ url: URL) -> Bool {
        guard isEnabled, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return allowedHosts.isEmpty || allowedHosts.contains(url.host?.lowercased() ?? "")
    }

    public static func assetURL(for url: URL) -> URL {
        guard shouldHandle(url), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.scheme = scheme + "-" + (url.scheme ?? "https")
        return comps.url ?? url
    }

    public static func originalURL(for assetURL: URL) -> URL {
        guard let rawScheme = assetURL.scheme, rawScheme.hasPrefix(scheme + "-"),
              var comps = URLComponents(url: assetURL, resolvingAgainstBaseURL: false) else { return assetURL }
        comps.scheme = String(rawScheme.dropFirst(scheme.count + 1))
        return comps.url ?? assetURL
    }

    public static func makeAsset(url: URL, options: [String: Any]?) -> AVURLAsset {
        guard shouldHandle(url) else { return AVURLAsset(url: url, options: options) }
        _ = removeStaleFiles
        let asset = AVURLAsset(url: assetURL(for: url), options: options)
        let loader = StreamResourceLoader(originalURL: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let key = ObjectIdentifier(asset)
        registryQueue.sync {
            registryOrder.removeAll { $0 == key }
            registry.removeValue(forKey: key)?.invalidate()
            registry[key] = loader
            registryOrder.append(key)
            while registryOrder.count > maxLiveLoaders {
                let old = registryOrder.removeFirst()
                registry.removeValue(forKey: old)?.invalidate()
            }
        }
        return asset
    }

    public static func release(asset: AVAsset?) {
        guard let asset = asset else { return }
        let key = ObjectIdentifier(asset)
        registryQueue.sync {
            registryOrder.removeAll { $0 == key }
            registry.removeValue(forKey: key)?.invalidate()
        }
    }

    // MARK: - Lifecycle

    private init(originalURL: URL) {
        self.originalURL = originalURL
        let name = Self.filePrefix + UUID().uuidString
        self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        super.init()
    }

    deinit { invalidateNow() }

    private func invalidate() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.invalidateNow()
        }
    }

    private func invalidateNow() {
        invalidated = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: fileURL)
        pending.forEach { if !$0.isFinished { $0.finishLoading(with: StreamError.cancelled) } }
        pending.removeAll()
    }

    // MARK: - Download

    private func startIfNeeded() {
        guard task == nil, !finished else { return }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            failDownload(with: StreamError.fileUnavailable)
            return
        }
        fileHandle = handle
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        startRequest()
    }

    // The first request is a plain GET because a cold CDN holds a range request until it has the whole file.
    // A resume after a dropped connection asks for the rest with a range, once that first request has started the CDN fetch.
    private func startRequest() {
        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        requestOffset = received
        if requestOffset > 0 {
            request.setValue("bytes=\(requestOffset)-", forHTTPHeaderField: "Range")
        }
        task = session?.dataTask(with: request)
        task?.resume()
    }

    private func canResume(after error: Error) -> Bool {
        let nsError = error as NSError
        guard failure == nil, !invalidated, resumeAttempts < Self.maxResumeAttempts else { return false }
        guard nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return false }
        return knownLength < 0 || received < knownLength
    }

    private func scheduleResume(after error: Error) {
        resumeAttempts += 1
        Self.log?("[StreamLoader] resume \(Self.trackId(originalURL)) attempt=\(resumeAttempts) from=\(received) error=\(error.localizedDescription)")
        queue.asyncAfter(deadline: .now() + .seconds(resumeAttempts)) { [weak self] in
            guard let self = self, !self.invalidated else { return }
            self.startRequest()
        }
    }

    private func acceptResumedResponse(_ response: HTTPURLResponse?, completionHandler: (URLSession.ResponseDisposition) -> Void) {
        guard response?.statusCode == 206, Self.contentRangeStart(response) == requestOffset else {
            completionHandler(.cancel)
            failDownload(with: StreamError.resumeRejected(response?.statusCode ?? 0))
            return
        }
        completionHandler(.allow)
    }

    private func failDownload(with error: Error) {
        failure = error
        finished = true
        task?.cancel()
        Self.log?("[StreamLoader] error \(Self.trackId(originalURL)) \(error.localizedDescription) received=\(received)")
        process()
    }

    private static func contentRangeStart(_ response: HTTPURLResponse?) -> Int64? {
        guard let value = response?.value(forHTTPHeaderField: "Content-Range") else { return nil }
        return value.split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
    }

    private static func trackId(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first { $0.name == "trackId" }?.value ?? String(url.absoluteString.suffix(12))
    }

    // MARK: - Serving AVFoundation

    private func process() {
        guard !pending.isEmpty else { return }
        var still: [AVAssetResourceLoadingRequest] = []
        for req in pending {
            if req.isCancelled || req.isFinished { continue }
            if let failure = failure { req.finishLoading(with: failure); continue }
            if let info = req.contentInformationRequest {
                guard httpStatus != 0, knownLength >= 0 else { still.append(req); continue }
                info.contentType = Self.utType(forMime: mimeType)
                info.contentLength = knownLength
                info.isByteRangeAccessSupported = true
            }
            guard let data = req.dataRequest else { req.finishLoading(); continue }
            let end: Int64 = data.requestsAllDataToEndOfResource
                ? (knownLength > 0 ? knownLength : Int64.max)
                : data.requestedOffset + Int64(data.requestedLength)
            var offset = data.currentOffset
            if offset < received && offset < end {
                let count = Int(min(received, end) - offset)
                guard let chunk = read(at: offset, count: count), !chunk.isEmpty else {
                    req.finishLoading(with: StreamError.fileUnavailable)
                    continue
                }
                data.respond(with: chunk)
                offset += Int64(chunk.count)
            }
            if offset >= end || (finished && offset >= received) {
                if finished && offset < end && received < end && !data.requestsAllDataToEndOfResource {
                    req.finishLoading(with: StreamError.truncated)
                } else {
                    req.finishLoading()
                }
            } else {
                still.append(req)
            }
        }
        pending = still
    }

    // In 7digital's fast-start files moov comes before mdat, the last box, whose header carries its size,
    // so the file length is known once the moov box has arrived, without another request
    private func probeLengthFromMP4() {
        guard knownLength < 0, !lengthProbeGaveUp else { return }
        while lengthProbeOffset + 16 <= received {
            guard let header = read(at: lengthProbeOffset, count: 16), header.count == 16 else { return }
            var size32: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &size32) { header.copyBytes(to: $0, from: 0..<4) }
            var boxSize = Int64(UInt32(bigEndian: size32))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if lengthProbeOffset == 0 && type != "ftyp" { lengthProbeGaveUp = true; return }
            if boxSize == 1 {
                var size64: UInt64 = 0
                _ = withUnsafeMutableBytes(of: &size64) { header.copyBytes(to: $0, from: 8..<16) }
                guard let largeSize = Int64(exactly: UInt64(bigEndian: size64)) else { lengthProbeGaveUp = true; return }
                boxSize = largeSize
            }
            guard boxSize >= 8, boxSize <= 1 << 40 else { lengthProbeGaveUp = true; return }
            if type == "moov" { lengthProbeSawMoov = true }
            if type == "mdat" {
                guard lengthProbeSawMoov else { lengthProbeGaveUp = true; return }
                knownLength = lengthProbeOffset + boxSize
                return
            }
            lengthProbeOffset += boxSize
        }
    }

    private func read(at offset: Int64, count: Int) -> Data? {
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return try? reader.read(upToCount: count)
    }

    private static func utType(forMime mime: String?) -> String {
        switch (mime ?? "").lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "audio/mpeg", "audio/mp3": return "public.mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "public.mpeg-4-audio"
        case "audio/aac", "audio/aacp": return "public.aac-audio"
        case "audio/flac", "audio/x-flac": return "org.xiph.flac"
        case "audio/wav", "audio/x-wav": return "com.microsoft.waveform-audio"
        default: return "public.audio"
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension StreamResourceLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !invalidated else { return false }
        pending.append(loadingRequest)
        startIfNeeded()
        process()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }
}

// MARK: - URLSessionDataDelegate

extension StreamResourceLoader: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === task else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        if requestOffset > 0 {
            acceptResumedResponse(http, completionHandler: completionHandler)
            return
        }
        httpStatus = http?.statusCode ?? 200
        mimeType = response.mimeType
        if response.expectedContentLength >= 0 { knownLength = response.expectedContentLength }
        if httpStatus >= 400 {
            failure = StreamError.badStatus(httpStatus)
            Self.log?("[StreamLoader] bad status \(httpStatus) \(Self.trackId(originalURL))")
            process()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
        process()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, failure == nil, let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failDownload(with: error)
            return
        }
        received += Int64(data.count)
        resumeAttempts = 0
        if knownLength < 0 { probeLengthFromMP4() }
        process()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let error = error, canResume(after: error) {
            scheduleResume(after: error)
            return
        }
        finished = true
        if error == nil { knownLength = received }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            failure = error
            Self.log?("[StreamLoader] error \(Self.trackId(originalURL)) \(error.localizedDescription) received=\(received)")
        }
        process()
    }
}
