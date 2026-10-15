//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
    case cleared
    case failed
}

public class AVPlayerWrapper: AVPlayerWrapperProtocol {
    // MARK: - Properties
    
    var avPlayer = AVQueuePlayer()
    private let playerObserver = AVPlayerObserver()
    internal let playerTimeObserver: AVPlayerTimeObserver
    private let playerItemNotificationObserver = AVPlayerItemNotificationObserver()
    private let playerItemObserver = AVPlayerItemObserver()
    fileprivate var timeToSeekToAfterLoading: TimeInterval?
    fileprivate var asset: AVAsset? = nil
    fileprivate var item: AVPlayerItem? = nil
    fileprivate var url: URL? = nil
    fileprivate var urlOptions: [String: Any]? = nil
    fileprivate let stateQueue = DispatchQueue(
        label: "AVPlayerWrapper.stateQueue",
        attributes: .concurrent
    )
    
    private var nextAsset: AVAsset?
    private var nextPreloadUrl: URL?
    private var wasPlayingBeforeStall = false
    
    public init() {
        playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())

        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        setupAVPlayer();
    }
    
    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var playbackError: AudioPlayerError.PlaybackError? = nil
    
    var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle
    var state: AVPlayerWrapperState {
        get {
            return stateQueue.sync { _state }
        }
        set {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                let currentState = self._state
                if currentState != newValue {
                    self._state = newValue
                    DispatchQueue.main.async {
                        self.delegate?.AVWrapper(didChangeState: newValue)
                    }
                }
            }
        }
    }

    fileprivate(set) var lastPlayerTimeControlStatus: AVPlayer.TimeControlStatus = AVPlayer.TimeControlStatus.paused

    /**
     Whether AVPlayer should start playing automatically when the item is ready.
     */
    public var playWhenReady: Bool = false {
        didSet {
            if (playWhenReady == true && (state == .failed || state == .stopped)) {
                reload(startFromCurrentTime: state == .failed)
            }

            applyAVPlayerRate()
            
            if oldValue != playWhenReady {
                delegate?.AVWrapper(didChangePlayWhenReady: playWhenReady)
            }
        }
    }
    
    var currentItem: AVPlayerItem? {
        avPlayer.currentItem
    }

    var playbackActive: Bool {
        switch state {
        case .idle, .stopped, .ended, .failed:
            return false
        default: return true
        }
    }
    
    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        avPlayer.reasonForWaitingToPlay
    }

    private var _rate: Float = 1.0;
    var rate: Float {
        get { _rate }
        set {
            _rate = newValue
            applyAVPlayerRate()
        }
    }

    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }
    
    func play() {
        playWhenReady = true
    }
    
    func pause() {
        playWhenReady = false
    }

    func recreatePlayer() {
        recreateAVPlayer()
    }
    
    func clearAvPlayerQueue() {
        PlayTrace.log("clear player queue \(PlayTrace.ids(avPlayer.items())), pending preload: \(nextAsset != nil)")
        avPlayer.removeAllItems()
    }

    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }
    
    func stop() {
        state = .stopped
        clearCurrentItem()
        playWhenReady = false
    }
    
    func seek(to seconds: TimeInterval) {
       // if the player is loading then we need to defer seeking until it's ready.
        if (avPlayer.currentItem == nil) {
         timeToSeekToAfterLoading = seconds
       } else {
           let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)
           avPlayer.seek(to: time, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero) { (finished) in
             self.delegate?.AVWrapper(seekTo: Double(seconds), didFinish: finished)
         }
       }
     }

    func seek(by seconds: TimeInterval) {
        if let currentItem = avPlayer.currentItem {
            let time = currentItem.currentTime().seconds + seconds
            avPlayer.seek(
                to: CMTimeMakeWithSeconds(time, preferredTimescale: 1000)
            ) { (finished) in
                  self.delegate?.AVWrapper(seekTo: Double(time), didFinish: finished)
            }
        } else {
            if let timeToSeekToAfterLoading = timeToSeekToAfterLoading {
                self.timeToSeekToAfterLoading = timeToSeekToAfterLoading + seconds
            } else {
                timeToSeekToAfterLoading = seconds
            }
        }
    }
    
    private func playbackFailed(error: AudioPlayerError.PlaybackError) {
        state = .failed
        self.playbackError = error
        self.delegate?.AVWrapper(failedWithError: error)
    }
    
    func load() {
        if state == .failed {
            recreateAVPlayer()
        }
        if let asset {
            asset.cancelLoading()
            self.asset = nil
        }
        self.stopObservingAVPlayerItem()
        guard let url = url else {
            nextAsset?.cancelLoading()
            return
        }
        state = .loading
        let traceId = PlayTrace.id(url)
        PlayTrace.log("load \(traceId), player has \(PlayTrace.ids(avPlayer.items()))")
        print("---- requesting new item \(url.absoluteString.suffix(10)) ")
        print("---- \(avPlayer.items().compactMap { ($0.asset as? AVURLAsset)?.url.absoluteString.suffix(10) })")
        if let item = avPlayer.items().first { ($0.asset as? AVURLAsset)?.url == url }, avPlayer.items().count == 2 {
            print("---- load existing item")
            PlayTrace.log("fast path: reusing preloaded \(traceId)")
            nextAsset = nil
            self.item = item
            self.avPlayer.advanceToNextItem()
            self.applyAVPlayerRate()
            self.asset = item.asset
            self.startObservingAVPlayer(item: item)
            self.applyAVPlayerRate()
            self.prefetchNextTracks()
            return;
        }
        // SLOW-START FIX: if the preloader is already fetching this exact URL, adopt that
        // in-flight asset instead of cancelling it and re-requesting the same URL. Field
        // traces showed cancel-then-reload of the same URL stalling inside AVFoundation for
        // 1.5-15 s (every slow song start in three user logs followed a
        // "preload keys done ... playable=cancelled" for the URL being loaded).
        if let inFlight = nextAsset as? AVURLAsset,
           inFlight.url == url,
           inFlight.statusOfValue(forKey: "playable", error: nil) == .loading {
            PlayTrace.log("adopting in-flight preload for \(traceId)")
            nextAsset = nil
            asset = inFlight
            awaitAssetKeys(inFlight, traceId: traceId, origin: "adopted preload")
            return
        }
        nextAsset?.cancelLoading()
        nextAsset = nil
        let pendingAsset = AVURLAsset(url: url, options: urlOptions)
        asset = pendingAsset
        PlayTrace.log("slow path: loading 5 keys for \(traceId)")
        pendingAsset.loadValuesAsynchronously(forKeys: ["playable"]) {
            PlayTrace.log("probe: playable \(PlayTrace.describe(pendingAsset.statusOfValue(forKey: "playable", error: nil))) for \(traceId)")
        }
        awaitAssetKeys(pendingAsset, traceId: traceId, origin: "slow path")
    }

    private static let assetKeys: [String] = [
        "playable",
        "availableChapterLocales",
        "availableMetadataFormats",
        "commonMetadata",
        "duration"
    ]

    /// Waits for the asset's keys (a no-op join if they are already loading) and hands the
    /// asset to handleLoadedAsset. Shared by the slow path and the adopted-preload path.
    private func awaitAssetKeys(_ pendingAsset: AVURLAsset, traceId: String, origin: String) {
        let keys = Self.assetKeys
        pendingAsset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let keyStatuses = keys.map { "\($0)=\(PlayTrace.describe(pendingAsset.statusOfValue(forKey: $0, error: nil)))" }
                PlayTrace.log("5 keys done (\(origin)) for \(traceId): \(keyStatuses.joined(separator: " "))")
                var error: NSError?
                let playableStatus = pendingAsset.statusOfValue(forKey: "playable", error: &error)
                switch playableStatus {
                case .cancelled, .loading, .unknown:
                    return
                case .failed:
                    self.playbackFailed(error: AudioPlayerError.PlaybackError.failedToLoadKeyValue)
                    return
                default: break
                }
                self.handleLoadedAsset(pendingAsset)
            }
        }
    }
    
    private func handleLoadedAsset(_ pendingAsset: AVURLAsset) {
        guard pendingAsset == asset else {
            PlayTrace.log("ignored stale asset \(PlayTrace.id(pendingAsset.url))")
            return
        }
        
        if !pendingAsset.isPlayable {
            playbackFailed(error: AudioPlayerError.PlaybackError.itemWasUnplayable)
            return
        }
        
        let keysToLoad: [String] = [
            "playable",
            "availableChapterLocales",
            "availableMetadataFormats",
            "commonMetadata",
            "duration"
        ]
        
        let item = AVPlayerItem(asset: pendingAsset, automaticallyLoadedAssetKeys: keysToLoad)
        self.item = item
        item.preferredForwardBufferDuration = self.bufferDuration
        print("---- avplayer removeallitems ----")
        self.avPlayer.removeAllItems()
        self.avPlayer.insert(item, after: nil)
        PlayTrace.log("item inserted \(PlayTrace.id(pendingAsset.url)), player has \(PlayTrace.ids(avPlayer.items()))")
        self.prefetchNextTracks()
        self.startObservingAVPlayer(item: item)
        self.applyAVPlayerRate()
        if !pendingAsset.availableChapterLocales.isEmpty {
            for locale in pendingAsset.availableChapterLocales {
                let chapters = pendingAsset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil)
                self.delegate?.AVWrapper(didReceiveMetadata: chapters)
            }
        } else {
            for format in pendingAsset.availableMetadataFormats {
                let timeRange = CMTimeRange(start: .zero, end: pendingAsset.duration)
                let group = AVTimedMetadataGroup(items: pendingAsset.metadata(forFormat: format), timeRange: timeRange)
                self.delegate?.AVWrapper(didReceiveMetadata: [group])
            }
        }
        
        if let initialTime = self.timeToSeekToAfterLoading {
            self.timeToSeekToAfterLoading = nil
            self.seek(to: initialTime)
        }
    }
    
    func prefetchNextTracks() {
        PlayTrace.log("preload requested for next: \(QueuedAudioPlayer.nextAudioItem.first?.getTitle() ?? "none")")
        QueuedAudioPlayer.nextAudioItem.first?.getSourceUrl({ [weak self] urlString in
            guard let self = self else { return }
            guard let url = URL(string: urlString) else { return }
            nextAsset = AVURLAsset(url: url)
            PlayTrace.log("preload loading keys for \(PlayTrace.id(url))")
            guard let asset = nextAsset else { return }
            let keys = [
                "playable",
                "availableChapterLocales",
                "availableMetadataFormats",
                "commonMetadata",
                "duration"
            ]
            asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
                guard let self = self else { return }
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                PlayTrace.log("preload keys done for \(PlayTrace.id(url)): playable=\(PlayTrace.describe(status))")
                guard status == .loaded else { return }
                
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 30
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                
                DispatchQueue.main.async {
                    let isLatestPreload = asset === self.nextAsset
                    let playerWasEmpty = self.avPlayer.items().isEmpty
                    let loadInProgress = self.state == .loading
                    // SLOW-START FIX: only the current preload may insert itself as the next
                    // item. A preload that load() adopted as the current asset, or that a newer
                    // preload replaced, must not be inserted a second time.
                    guard isLatestPreload else {
                        PlayTrace.log("preload superseded, not inserting \(PlayTrace.id(url))")
                        return
                    }
                    if self.avPlayer.items().count > 1 {
                        let nextItems = self.avPlayer.items().dropFirst()
                        nextItems.forEach { self.avPlayer.remove($0) }
                    }
                    self.avPlayer.insert(item, after: nil)
                    PlayTrace.log("preload inserted \(PlayTrace.id(url)) latest=\(isLatestPreload) playerWasEmpty=\(playerWasEmpty) loadInProgress=\(loadInProgress), player has \(PlayTrace.ids(self.avPlayer.items()))")
                    print("---- preload next item \((self.avPlayer.items().compactMap { ($0.asset as? AVURLAsset)?.url.absoluteString.suffix(10) }).joined(separator: "  ||  ") ) ")
                }
            }
        })
    }
    
    func preloadNextTracks(_ url: URL) {
        guard !avPlayer.items().contains(where: { ($0.asset as? AVURLAsset)?.url == url} ) else { return }
        self.nextPreloadUrl = url
    }

    func clearPreloadedTracks() {
        avPlayer.removeAllItems()
    }

    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        self.playWhenReady = playWhenReady
        self.url = url
        self.urlOptions = options
        self.load()
    }
    
    func load(
        from url: URL,
        playWhenReady: Bool,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        self.load(from: url, playWhenReady: playWhenReady, options: options)
        if let initialTime = initialTime {
            self.seek(to: initialTime)
        }
    }

    func load(
        from url: String,
        type: SourceType = .stream,
        playWhenReady: Bool = false,
        initialTime: TimeInterval? = nil,
        options: [String : Any]? = nil
    ) {
        if let itemUrl = type == .file
            ? URL(fileURLWithPath: url)
            : URL(string: url)
        {
            self.load(from: itemUrl, playWhenReady: playWhenReady, options: options)
            if let initialTime = initialTime {
                self.seek(to: initialTime)
            }
        } else {
            clearCurrentItem()
            playbackFailed(error: AudioPlayerError.PlaybackError.invalidSourceUrl(url))
        }
    }

    func unload() {
        clearCurrentItem()
        state = .idle
    }

    func reload(startFromCurrentTime: Bool) {
        var time : Double? = nil
        if (startFromCurrentTime) {
            if let currentItem = currentItem {
                if (!currentItem.duration.isIndefinite) {
                    time = currentItem.currentTime().seconds
                }
            }
        }
        load()
        if let time = time {
            seek(to: time)
        }
    }
    
    // MARK: - Util

    private func clearCurrentItem() {
        guard let asset = asset else { return }
        PlayTrace.log("clear current item \(PlayTrace.id((asset as? AVURLAsset)?.url)), pending preload: \(nextAsset != nil)")
        stopObservingAVPlayerItem()
        
        asset.cancelLoading()
        self.asset = nil
        
        avPlayer.replaceCurrentItem(with: nil)
    }
    
    private func startObservingAVPlayer(item: AVPlayerItem) {
        playerItemObserver.startObserving(item: item)
        playerItemNotificationObserver.startObserving(item: item)
    }

    private func stopObservingAVPlayerItem() {
        playerItemObserver.stopObservingCurrentItem()
        playerItemNotificationObserver.stopObservingCurrentItem()
    }
    
    func recreateAVPlayer() {
        playbackError = nil
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerTimeObserver.unregisterForPeriodicEvents()
        playerObserver.stopObserving()
        stopObservingAVPlayerItem()
        clearCurrentItem()

        avPlayer = AVQueuePlayer();
        setupAVPlayer()

        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
    private func setupAVPlayer() {
        // disabled since we're not making use of video playback
        avPlayer.allowsExternalPlayback = false;
        AudioPlayer.avPlayerRef = avPlayer
        playerObserver.player = avPlayer
        playerObserver.startObserving()

        playerTimeObserver.player = avPlayer
        playerTimeObserver.registerForBoundaryTimeEvents()
        playerTimeObserver.registerForPeriodicTimeEvents()

        applyAVPlayerRate()
        avPlayer.actionAtItemEnd = .none
    }
    
    private func applyAVPlayerRate() {
        avPlayer.rate = playWhenReady ? _rate : 0
    }
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        let waitingReason = status == .waitingToPlayAtSpecifiedRate ? " (\(avPlayer.reasonForWaitingToPlay?.rawValue ?? "no reason"))" : ""
        PlayTrace.log("timeControlStatus \(PlayTrace.describe(status))\(waitingReason) for \(PlayTrace.id((avPlayer.currentItem?.asset as? AVURLAsset)?.url))")
        switch status {
        case .paused:
            let state = self.state
            if self.asset == nil && state != .stopped {
                self.state = .idle
            } else if (state != .failed && state != .stopped) {
                // Playback may have become paused externally for example due to a bluetooth device disconnecting,
                // or a buffer stall when automaticallyWaitsToMinimizeStalling = false:
                if (self.playWhenReady) {
                    // Only if we are not on the boundaries of the track, otherwise itemDidPlayToEndTime will handle it instead.
                    if (self.currentTime > 0 && self.currentTime < self.duration) {
                        wasPlayingBeforeStall = true
                        self.playWhenReady = false
                    }
                } else {
                    self.state = .paused
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            if self.asset != nil {
                self.state = .buffering
            }
        case .playing:
            wasPlayingBeforeStall = false
            self.state = .playing
            if let event = avPlayer.currentItem?.accessLog()?.events.last {
                let startup = String(format: "%.2f", event.startupTime)
                let transfer = String(format: "%.2f", event.transferDuration)
                PlayTrace.log("access log: startup \(startup)s, \(event.numberOfMediaRequests) requests, \(event.numberOfBytesTransferred / 1024) KB in \(transfer)s, server changes \(event.numberOfServerAddressChanges)")
            }
        @unknown default:
            break
        }
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        if (status == .failed) {
            let error = item!.error as NSError?
            playbackFailed(error: error?.code == URLError.notConnectedToInternet.rawValue
                 ? AudioPlayerError.PlaybackError.notConnectedToInternet
                 : AudioPlayerError.PlaybackError.playbackFailed
            )
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        PlayTrace.log("audio started")
        state = .playing
    }
    
    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    // MARK: - AVPlayerItemNotificationObserverDelegate

    func itemFailedToPlayToEndTime() {
        playbackFailed(error: AudioPlayerError.PlaybackError.playbackFailed)
        delegate?.AVWrapperItemFailedToPlayToEndTime()
    }
    
    func itemPlaybackStalled() {
        delegate?.AVWrapperItemPlaybackStalled()
    }
    
    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    // MARK: - AVPlayerItemObserverDelegate

    func item(didUpdatePlaybackLikelyToKeepUp playbackLikelyToKeepUp: Bool) {
        PlayTrace.log("likelyToKeepUp \(playbackLikelyToKeepUp)")
        if playbackLikelyToKeepUp && state != .playing {
            state = .ready
            if wasPlayingBeforeStall {
                wasPlayingBeforeStall = false
                playWhenReady = true
            }
        }
    }
        
    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
    func item(didReceiveMetadata metadata: [AVTimedMetadataGroup]) {
        delegate?.AVWrapper(didReceiveMetadata: metadata)
    }
}

public enum PlayTrace {
    public static var output: ((String) -> Void)?
    private static let lock = NSLock()
    private static var start = ProcessInfo.processInfo.systemUptime
    private static var last = ProcessInfo.processInfo.systemUptime

    public static func begin(_ message: String) {
        lock.lock()
        start = ProcessInfo.processInfo.systemUptime
        last = start
        lock.unlock()
        write("[PlayTrace] ==== " + message)
    }

    public static func log(_ message: String) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let line = String(format: "[PlayTrace] +%.0fms (+%.0fms) ", (now - start) * 1000, (now - last) * 1000) + message
        last = now
        lock.unlock()
        write(line)
    }

    private static func write(_ line: String) {
        if let output = output {
            output(line)
        } else {
            NSLog("%@", line)
        }
    }

    public static func id(_ url: URL?) -> String {
        guard let url = url else { return "none" }
        if url.isFileURL {
            return "file " + url.lastPathComponent
        }
        let trackId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "trackId" })?
            .value
        return trackId ?? String(url.absoluteString.suffix(10))
    }

    public static func ids(_ items: [AVPlayerItem]) -> String {
        "[" + items.map { id(($0.asset as? AVURLAsset)?.url) }.joined(separator: ", ") + "]"
    }

    public static func describe(_ status: AVKeyValueStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "other"
        }
    }

    public static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "other"
        }
    }
}
