//
//  QueuedAudioPlayer.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 24/03/2018.
//

import Foundation
import MediaPlayer

/**
 An audio player that can keep track of a queue of AudioItems.
 */
public class QueuedAudioPlayer: AudioPlayer, QueueManagerDelegate {
    let queue: QueueManager = QueueManager<AudioItem>()
    fileprivate var lastIndex: Int = -1
    fileprivate var lastItem: AudioItem? = nil

    public override init(nowPlayingInfoController: NowPlayingInfoControllerProtocol = NowPlayingInfoController(), remoteCommandController: RemoteCommandController = RemoteCommandController()) {
        super.init(nowPlayingInfoController: nowPlayingInfoController, remoteCommandController: remoteCommandController)
        queue.delegate = self
    }

    /// The repeat mode for the queue player.
    public var repeatMode: RepeatMode = .off
    
    public var preloadingQueue = false
    
    public var isOfflineMode = false
    
    static var nextAudioItem = [AudioItem]()
    
    public override var currentItem: AudioItem? {
        queue.current
    }

    /**
     The index of the current item.
     */
    public var currentIndex: Int {
        queue.currentIndex
    }

    override public func clear() {
        queue.clearQueue()
        clearUnderlyingPlayerQueue()
        super.clear()
    }

    /**
     All items currently in the queue.
     */
    public var items: [AudioItem] {
        queue.items
    }

    /**
     The previous items held by the queue.
     */
    public var previousItems: [AudioItem] {
        queue.previousItems
    }

    /**
     The upcoming items in the queue.
     */
    public var nextItems: [AudioItem] {
        queue.nextItems
    }

    /**
     Will replace the current item with a new one and load it into the player.

     - parameter item: The AudioItem to replace the current item.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */

    public override func load(item: AudioItem, playWhenReady: Bool? = nil, url: String? = nil) {
        applyPlayWhenReady(playWhenReady)
        queue.replaceCurrentItem(with: item)
    }

    /**
     Add a single item to the queue.

     - parameter item: The item to add.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(item: AudioItem, playWhenReady: Bool? = nil) {
        applyPlayWhenReady(playWhenReady)
        queue.add(item)
    }

    /**
     Add items to the queue.

     - parameter items: The items to add to the queue.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     */
    public func add(items: [AudioItem], playWhenReady: Bool? = nil) {
        applyPlayWhenReady(playWhenReady)
        queue.add(items)
    }

    public func add(items: [AudioItem], at index: Int) throws {
        try queue.add(items, at: index)
        if index == currentIndex + 1 {
            updatePrefetchedSongs()
        }
    }
    
    public func add(items: [AudioItem], playingIndex: Int, seekTo rate: Double) throws {
        playWhenReady = false
        queue.add(items)
        try queue.jump(to: playingIndex)
        wrapper.seek(to: rate)
        wrapper.pause()
    }

    /**
     Step to the next item in the queue.
     */
    public func next() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive
        if let offlineIndex = nextOfflineIndex() {
            _ = try? queue.jump(to: offlineIndex)
        } else {
            _ = queue.next(wrap: repeatMode == .queue)
        }
        if shouldEmitSkipEvent(playbackWasActive: playbackWasActive, previousIndex: lastIndex) {
            event.playbackEnd.emit(data: .skippedToNext)
        }
    }

    private func nextOfflineIndex() -> Int? {
        guard isOfflineMode,
              let nextOffline = queue.nextItems.first(where: { $0.getSourceType() == .offline }) else {
            return nil
        }
        return queue.items.firstIndex(where: { $0.id == nextOffline.id })
    }

    private func shouldEmitSkipEvent(playbackWasActive: Bool, previousIndex: Int) -> Bool {
        (playbackWasActive && previousIndex != currentIndex) || repeatMode == .queue
    }

    private func applyPlayWhenReady(_ value: Bool?) {
        guard let value else { return }
        playWhenReady = value
    }

    /**
     Step to the previous item in the queue.
     */
    public func previous() {
        let lastIndex = currentIndex
        let playbackWasActive = wrapper.playbackActive
        _ = queue.previous(wrap: repeatMode == .queue)
        if shouldEmitSkipEvent(playbackWasActive: playbackWasActive, previousIndex: lastIndex) {
            event.playbackEnd.emit(data: .skippedToPrevious)
        }
    }

    /**
     Remove an item from the queue.

     - parameter index: The index of the item to remove.
     - throws: `AudioPlayerError.QueueError`
     */
    public func removeItem(at index: Int) throws {
        _ = try queue.removeItem(at: index)
    }


    /**
     Jump to a certain item in the queue.

     - parameter index: The index of the item to jump to.
     - parameter playWhenReady: Optional, whether to start playback when the item is ready.
     - throws: `AudioPlayerError`
     */
    public func jumpToItem(atIndex index: Int, playWhenReady: Bool? = nil) throws {
        applyPlayWhenReady(playWhenReady)
        if (index == currentIndex) {
            seek(to: 0)
        } else {
            _ = try queue.jump(to: index)
        }
        event.playbackEnd.emit(data: .jumpedToIndex)
    }

    /**
     Move an item in the queue from one position to another.

     - parameter fromIndex: The index of the item to move.
     - parameter toIndex: The index to move the item to.
     - throws: `AudioPlayerError.QueueError`
     */
    public func moveItem(fromIndex: Int, toIndex: Int) throws {
        try queue.moveItem(fromIndex: fromIndex, toIndex: toIndex)
        if toIndex == currentIndex + 1 {
            updatePrefetchedSongs()
        }
    }

    /**
     Remove all upcoming items, those returned by `next()`
     */
    public func removeUpcomingItems() {
        queue.removeUpcomingItems()
    }

    /**
     Remove all previous items, those returned by `previous()`
     */
    public func removePreviousItems() {
        queue.removePreviousItems()
    }

    func replay() {
        guard let currentItem else { return }
        clearUnderlyingPlayerQueue()
        load(item: currentItem)
    }
    
    public func setOfflineMode(_ isOn: Bool) {
        self.isOfflineMode = isOn
    }

    // MARK: - AVPlayerWrapperDelegate
    
    override func AVWrapper(didChangeState state: AVPlayerWrapperState) {
        super.AVWrapper(didChangeState: state)
        if state == .loading {
            self.queue.nextItems.first?.getSourceUrl { url in
                guard let preloadUrl = URL(string: url) else { return }
                super.wrapper.preloadNextTracks(preloadUrl)
            }
        }
        
    }

    override func AVWrapperItemDidPlayToEndTime() {
        event.playbackEnd.emit(data: .playedUntilEnd)
        if (repeatMode == .track) {
            // quick workaround for race condition - place call bottom of call stack
            DispatchQueue.main.async { [weak self] in self?.replay() }
        } else if (repeatMode == .queue) {
            _ = queue.next(wrap: true)
        } else if (currentIndex != items.count - 1) {
            if let offlineIndex = nextOfflineIndex() {
                _ = try? queue.jump(to: offlineIndex)
            } else {
                _ = queue.next(wrap: false)
            }
        } else {
            wrapper.state = .ended
        }
    }

    // MARK: - QueueManagerDelegate
    

    func onItemMoveEvent() {
        event.onItemMoveEvent.emit(data: ())
    }

    func onCurrentItemChanged() {
        Self.nextAudioItem = nextItems
        let lastPosition = currentTime;
        if let currentItem = currentItem {
            currentItem.getSourceUrl { url in
                super.load(item: currentItem, playWhenReady: !self.preloadingQueue, url: url)
            }
        } else {
            super.clear()
        }
        event.currentItem.emit(
            data: (
                item: currentItem,
                index: currentIndex == -1 ? nil : currentIndex,
                lastItem: lastItem,
                lastIndex: lastIndex == -1 ? nil : lastIndex,
                lastPosition: lastPosition
            )
        )
        lastItem = currentItem
        lastIndex = currentIndex
    }

    func onSkippedToSameCurrentItem() {
        if (wrapper.playbackActive) {
            replay()
        }
    }

    func onReceivedFirstItem() {
        do {
            try queue.jump(to: 0)
        } catch {
            assertionFailure("Unexpected failure when setting first queue item: \(error)")
        }
    }
    
    private func clearUnderlyingPlayerQueue() {
        wrapper.clearAvPlayerQueue()
    }
    
    public func updatePrefetchedSongs() {
        Self.nextAudioItem = nextItems
        (wrapper as? AVPlayerWrapper)?.prefetchNextTracks()
    }
}
